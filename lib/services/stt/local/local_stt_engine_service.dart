import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/local_stt_worker.dart';

/// Pending chunk buffered while the worker isolate is starting up or respawning.
class _PendingChunk {
  final String filePath;
  final String chunkId;
  final double offsetSeconds;
  const _PendingChunk(this.filePath, this.chunkId, this.offsetSeconds);
}

/// Owns the local STT worker isolate and exposes a **typed** API for the
/// recording pipeline and voice enrollment.
///
/// Unlike the previous [LocalSttSocket], this service does **not** pretend
/// to be a cloud WebSocket. It doesn't implement `IPureSocket` and doesn't
/// route segments through the Deepgram-oriented [TranscriptSegmentSocketService].
/// Callbacks hand over parsed `List<TranscriptSegment>` directly.
///
/// The underlying worker protocol (tagged lists over a [SendPort]) is the
/// same one used by [LocalSttSocket] today — this class is a drop-in
/// replacement at the boundary with the pipeline.
///
/// Features (ported from [LocalSttSocket]):
/// - Isolate spawn + handshake with timeout.
/// - Heartbeat ping/pong (10s interval, 15s timeout) → respawn on stall.
/// - Circuit breaker after 5 consecutive worker errors.
/// - Streaming stall watchdog (60s with VAD active) → health change.
/// - Pending chunk queue (up to 12 × 5s chunks) while worker is unavailable.
/// - Streaming watermark (max emitted endTime) exposed to
///   [ChunkQueueManager] for fallback filtering.
class LocalSttEngineService {
  LocalSttEngineService({
    required String modelPath,
    LocalSttModelType modelType = LocalSttModelType.parakeet,
    String? speakerModelPath,
    Uint8List? userEmbeddingBytes,
    double? maxSpeechDuration,
    int? numThreads,
    String? acousticProfileJson,
  })  : _modelPath = modelPath,
        _modelType = modelType,
        _speakerModelPath = speakerModelPath,
        _userEmbeddingBytes = userEmbeddingBytes,
        _maxSpeechDuration = maxSpeechDuration,
        _numThreads = numThreads,
        _acousticProfileJson = acousticProfileJson;

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------
  final String _modelPath;
  final String? _speakerModelPath;
  final Uint8List? _userEmbeddingBytes;
  final LocalSttModelType _modelType;
  final double? _maxSpeechDuration;
  final int? _numThreads;
  final String? _acousticProfileJson;

  // ---------------------------------------------------------------------------
  // Isolate state
  // ---------------------------------------------------------------------------
  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  ReceivePort? _mainReceivePort;
  StreamSubscription? _mainReceiveSubscription;
  Completer<void>? _initCompleter;
  Completer<void>? _flushCompleter;
  bool _isConnected = false;

  // ---------------------------------------------------------------------------
  // Circuit breaker
  // ---------------------------------------------------------------------------
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 5;
  bool _circuitOpen = false;

  // ---------------------------------------------------------------------------
  // Pending chunks (buffered while worker is down)
  // ---------------------------------------------------------------------------
  final List<_PendingChunk> _pendingChunks = [];
  static const int _maxPendingChunks = 12; // ~60s of audio (12 × 5s chunks)

  // ---------------------------------------------------------------------------
  // Heartbeat
  // ---------------------------------------------------------------------------
  Timer? _heartbeatTimer;
  DateTime? _lastPong;
  bool _isRespawning = false;
  static const Duration _heartbeatInterval = Duration(seconds: 10);
  static const Duration _heartbeatTimeout = Duration(seconds: 15);

  // ---------------------------------------------------------------------------
  // Streaming fast path state
  // ---------------------------------------------------------------------------
  /// Max endTime (seconds) from any segment emitted via streaming. The queue
  /// manager uses this to skip chunks already covered when falling back to
  /// chunk decode.
  double _streamingWatermark = 0.0;
  bool _isStreamingHealthy = true;
  DateTime? _lastStreamResultAt;
  bool _vadActive = false;

  Timer? _streamingWatchdog;
  static const Duration _streamingWatchdogInterval = Duration(seconds: 10);
  static const Duration _streamingStallTimeout = Duration(seconds: 60);

  // ---------------------------------------------------------------------------
  // Public typed callbacks
  // ---------------------------------------------------------------------------

  /// Segments emitted by the worker (streaming fast path OR chunk decode OR
  /// final flush). Already parsed into [TranscriptSegment] objects — no JSON
  /// decode needed by the caller.
  void Function(List<TranscriptSegment> segments)? onSegments;

  /// VAD transitioned between speech-active and silence.
  void Function(bool active)? onVadStateChanged;

  /// Streaming health flipped. The pipeline uses this to toggle the queue
  /// manager between stream-primary and chunk-primary modes.
  void Function(bool healthy, String reason)? onStreamingHealthChanged;

  /// A chunk file finished processing (only fires for chunk-based decode).
  void Function(String chunkId)? onChunkProcessed;

  /// Fatal worker errors (circuit breaker, respawn failures).
  void Function(Object err, StackTrace trace)? onError;

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------

  bool get isConnected => _isConnected;
  bool get isStreamingHealthy => _isStreamingHealthy;
  double get streamingWatermark => _streamingWatermark;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Spawn the worker isolate, send the init command with model paths, and
  /// wait for the 'ready' handshake. Returns `true` on success.
  Future<bool> connect() async {
    if (_isConnected) return false;

    if (_modelPath.isEmpty) {
      debugPrint('[LocalSttEngineService] ERROR: model path is empty');
      return false;
    }

    try {
      _mainReceivePort = ReceivePort();
      _mainReceiveSubscription =
          _mainReceivePort!.listen(_handleWorkerMessage);

      _workerIsolate = await Isolate.spawn(
        workerEntryPoint,
        _mainReceivePort!.sendPort,
        debugName: 'local-stt-engine',
      );

      final handshakeCompleter = Completer<SendPort>();
      _initCompleter = Completer<void>();

      _mainReceiveSubscription!.onData((message) {
        if (message is SendPort) {
          handshakeCompleter.complete(message);
          _mainReceiveSubscription!.onData(_handleWorkerMessage);
        }
      });

      _workerSendPort = await handshakeCompleter.future
          .timeout(const Duration(seconds: 10));

      _workerSendPort!.send([
        'init',
        _modelPath,
        _speakerModelPath,
        _userEmbeddingBytes,
        _modelType.name,
        _maxSpeechDuration,
        _numThreads,
        _acousticProfileJson,
      ]);

      await _initCompleter!.future.timeout(const Duration(seconds: 30));
      _initCompleter = null;

      _isConnected = true;
      _circuitOpen = false;
      _consecutiveErrors = 0;
      _streamingWatermark = 0.0;
      _lastStreamResultAt = null;
      _vadActive = false;
      _setStreamingHealth(true, 'connected');
      _startHeartbeat();
      _startStreamingWatchdog();
      return true;
    } catch (e, trace) {
      debugPrint('[LocalSttEngineService] Connect failed: $e');
      onError?.call(e, trace);
      _cleanup();
      return false;
    }
  }

  /// Flush any pending VAD tail and shut down the worker gracefully.
  Future<void> disconnect() async {
    if (!_isConnected) return;
    await flush();
    _stopHeartbeat();
    _stopStreamingWatchdog();
    _shutdownWorker();
    _isConnected = false;
  }

  /// Flush remaining VAD tail without shutting down the worker.
  Future<void> flush() async {
    if (_workerSendPort == null) return;
    _flushCompleter = Completer<void>();
    _workerSendPort!.send(['flush']);
    try {
      await _flushCompleter!.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      debugPrint('[LocalSttEngineService] Flush timed out after 5s');
    } finally {
      _flushCompleter = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Audio ingestion
  // ---------------------------------------------------------------------------

  /// Streaming fast path: push raw PCM16 bytes for in-memory VAD + decode.
  /// The worker replies with `stream_result`.
  void pushAudio(Uint8List pcm16) {
    if (_workerSendPort == null) return;
    _workerSendPort!.send(['send_audio', pcm16]);
  }

  /// Chunk-based decode: ask the worker to read and decode a PCM16 file from
  /// disk. Used as fallback when streaming is unhealthy and for crash recovery.
  void processChunkFile(String filePath, String chunkId, double offsetSeconds) {
    if (_circuitOpen) {
      debugPrint(
          '[LocalSttEngineService] Circuit open, skipping chunk $chunkId');
      onChunkProcessed?.call(chunkId);
      return;
    }

    if (_workerSendPort == null) {
      if (_pendingChunks.length >= _maxPendingChunks) {
        _pendingChunks.removeAt(0);
        debugPrint(
            '[LocalSttEngineService] Pending queue full, dropping oldest');
      }
      _pendingChunks.add(_PendingChunk(filePath, chunkId, offsetSeconds));
      return;
    }

    _workerSendPort!.send(['process_chunk', filePath, chunkId, offsetSeconds]);
  }

  // ---------------------------------------------------------------------------
  // Worker message routing
  // ---------------------------------------------------------------------------

  void _handleWorkerMessage(dynamic message) {
    if (message is! List || message.isEmpty) return;

    final type = message[0] as String;
    switch (type) {
      case 'ready':
        _initCompleter?.complete();
        _drainPendingChunks();

      case 'pong':
        _lastPong = DateTime.now();

      case 'error':
        final errorMsg = message.length > 1 ? message[1] as String : 'Unknown';
        final stackStr = message.length > 2 ? message[2] as String? : null;
        debugPrint('[LocalSttEngineService] Worker error: $errorMsg');
        final trace = stackStr != null
            ? StackTrace.fromString(stackStr)
            : StackTrace.current;

        _consecutiveErrors++;
        if (_consecutiveErrors >= _maxConsecutiveErrors && !_circuitOpen) {
          _circuitOpen = true;
          debugPrint('[LocalSttEngineService] Circuit breaker OPEN '
              'after $_consecutiveErrors consecutive errors');
          _setStreamingHealth(false, 'circuit_open');
        }

        onError?.call(Exception(errorMsg), trace);

        if (_initCompleter != null && !_initCompleter!.isCompleted) {
          _initCompleter!.completeError(Exception(errorMsg));
        }

      case 'chunk_result':
        final chunkId = message.length > 1 ? message[1] as String : '';
        final jsonSegments =
            message.length > 2 ? message[2] as String? : null;
        final vadActive = message.length > 3 ? message[3] as bool : false;

        if (jsonSegments != null) {
          _consecutiveErrors = 0;
          _emitSegmentsFromJson(jsonSegments);
        }
        _vadActive = vadActive;
        onVadStateChanged?.call(vadActive);
        onChunkProcessed?.call(chunkId);

      case 'stream_result':
        final jsonSegments =
            message.length > 1 ? message[1] as String? : null;
        final vadActive = message.length > 2 ? message[2] as bool : false;

        _lastStreamResultAt = DateTime.now();
        _vadActive = vadActive;

        if (jsonSegments != null) {
          _consecutiveErrors = 0;
          _emitSegmentsFromJson(jsonSegments);
        }
        if (!_isStreamingHealthy) {
          _setStreamingHealth(true, 'stream_result_ok');
        }
        onVadStateChanged?.call(vadActive);

      case 'flushed':
        if (message.length > 1 && message[1] is String) {
          _emitSegmentsFromJson(message[1] as String);
        }
        _flushCompleter?.complete();

      case 'vad_state':
        if (message.length > 1) {
          final active = message[1] as bool;
          _vadActive = active;
          onVadStateChanged?.call(active);
        }
    }
  }

  /// Decode a JSON segment array coming from the worker **once**, build
  /// typed [TranscriptSegment]s, update the streaming watermark, and invoke
  /// [onSegments]. This is the single decode boundary — callers never see
  /// the JSON string.
  void _emitSegmentsFromJson(String jsonSegments) {
    try {
      final decoded = jsonDecode(jsonSegments);
      if (decoded is! List) return;
      final segments = decoded
          .whereType<Map<String, dynamic>>()
          .map(TranscriptSegment.fromJson)
          .toList();

      for (final seg in segments) {
        if (seg.end > _streamingWatermark) {
          _streamingWatermark = seg.end;
        }
      }

      if (segments.isNotEmpty) {
        onSegments?.call(segments);
      }
    } catch (e, trace) {
      debugPrint('[LocalSttEngineService] Decode error: $e');
      onError?.call(e, trace);
    }
  }

  // ---------------------------------------------------------------------------
  // Heartbeat + respawn
  // ---------------------------------------------------------------------------

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPong = DateTime.now();
    _heartbeatTimer =
        Timer.periodic(_heartbeatInterval, (_) => _checkHeartbeat());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _checkHeartbeat() {
    if (_workerSendPort == null || _isRespawning) return;
    _workerSendPort!.send(['ping']);

    if (_lastPong != null &&
        DateTime.now().difference(_lastPong!) > _heartbeatTimeout) {
      debugPrint('[LocalSttEngineService] Heartbeat timeout — respawning');
      _respawnWorker();
    }
  }

  Future<void> _respawnWorker() async {
    if (_isRespawning) return;
    _isRespawning = true;
    _stopHeartbeat();
    _stopStreamingWatchdog();
    _setStreamingHealth(false, 'worker_respawn');

    try {
      _workerIsolate?.kill(priority: Isolate.beforeNextEvent);
      _cleanup();

      final success = await connect();
      if (!success) {
        onError?.call(
            Exception('Worker respawn failed'), StackTrace.current);
      }
    } catch (e, trace) {
      debugPrint('[LocalSttEngineService] Respawn error: $e');
      onError?.call(e, trace);
    } finally {
      _isRespawning = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Streaming watchdog
  // ---------------------------------------------------------------------------

  void _startStreamingWatchdog() {
    _streamingWatchdog?.cancel();
    _streamingWatchdog = Timer.periodic(
      _streamingWatchdogInterval,
      (_) => _checkStreamingStall(),
    );
  }

  void _stopStreamingWatchdog() {
    _streamingWatchdog?.cancel();
    _streamingWatchdog = null;
  }

  /// Detects "worker alive but not producing segments during active speech".
  /// Heartbeat catches dead isolates; this catches wedged ones.
  void _checkStreamingStall() {
    if (!_vadActive) return;
    if (_lastStreamResultAt == null) return;
    final stalled = DateTime.now().difference(_lastStreamResultAt!) >
        _streamingStallTimeout;
    if (stalled && _isStreamingHealthy) {
      debugPrint('[LocalSttEngineService] Streaming stalled '
          '(no stream_result in ${_streamingStallTimeout.inSeconds}s with VAD active)');
      _setStreamingHealth(false, 'stream_stall');
    }
  }

  void _setStreamingHealth(bool healthy, String reason) {
    if (_isStreamingHealthy == healthy) return;
    _isStreamingHealthy = healthy;
    debugPrint('[LocalSttEngineService] Streaming health → '
        '${healthy ? "HEALTHY" : "UNHEALTHY"} ($reason)');
    onStreamingHealthChanged?.call(healthy, reason);
  }

  // ---------------------------------------------------------------------------
  // Pending chunks
  // ---------------------------------------------------------------------------

  void _drainPendingChunks() {
    if (_pendingChunks.isEmpty) return;
    debugPrint(
        '[LocalSttEngineService] Draining ${_pendingChunks.length} pending chunks');
    final chunks = List<_PendingChunk>.from(_pendingChunks);
    _pendingChunks.clear();
    for (final p in chunks) {
      processChunkFile(p.filePath, p.chunkId, p.offsetSeconds);
    }
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  void _shutdownWorker() {
    _workerSendPort?.send(['shutdown']);
    final isolate = _workerIsolate;
    if (isolate != null) {
      Future.delayed(const Duration(milliseconds: 500), () {
        isolate.kill(priority: Isolate.beforeNextEvent);
      });
    }
    _cleanup();
  }

  void _cleanup() {
    _mainReceiveSubscription?.cancel();
    _mainReceiveSubscription = null;
    _mainReceivePort?.close();
    _mainReceivePort = null;
    _workerSendPort = null;
    _workerIsolate = null;
    _initCompleter = null;
    _flushCompleter = null;
    _streamingWatchdog?.cancel();
    _streamingWatchdog = null;
  }
}
