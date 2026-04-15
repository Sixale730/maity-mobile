import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/local_stt_worker.dart';
import 'package:omi/services/sockets/pure_socket.dart';

/// Pending chunk buffered while the worker isolate is starting up.
class _PendingChunk {
  final String filePath;
  final String chunkId;
  final double offsetSeconds;
  const _PendingChunk(this.filePath, this.chunkId, this.offsetSeconds);
}

/// IPureSocket adapter that bridges a worker isolate running [LocalSttEngine]
/// to the transcription pipeline.
///
/// In the chunk-based pipeline, audio is written to disk by [AudioChunkWriter]
/// and this socket sends `processChunk` commands to the worker isolate to
/// decode each chunk file. Results flow back via [onMessage] in the same
/// JSON format the pipeline expects.
///
/// All heavy FFI work (VAD + decode) runs in the worker isolate, so the main
/// isolate is never blocked. Each [connect] spawns a fresh worker with a fresh
/// engine, eliminating stale VAD state between reconnects.
///
/// Resilience features:
/// - **Circuit breaker**: After [_maxConsecutiveErrors] consecutive errors,
///   stops sending chunks to prevent battery drain from a broken worker.
/// - **Pending queue**: Buffers up to [_maxPendingChunks] chunks while the
///   worker is connecting/respawning, drained on 'ready'.
/// - **Heartbeat**: Ping/pong every [_heartbeatInterval]; if no pong within
///   [_heartbeatTimeout], kills and respawns the worker.
class LocalSttSocket implements IPureSocket {
  PureSocketStatus _status = PureSocketStatus.notConnected;
  IPureSocketListener? _listener;
  final String? _modelPath;
  final String? _speakerModelPath;
  final Uint8List? _userEmbeddingBytes;
  final LocalSttModelType _modelType;
  final double? _maxSpeechDuration;
  final int? _numThreads;
  final String? _acousticProfileJson;

  /// Callback for VAD state transitions (replaces preview text).
  /// Called when the VAD detects speech start/end during chunk processing.
  void Function(bool isSpeechActive)? onVadStateChanged;

  /// Callback when a chunk has been fully processed.
  /// The [chunkId] is the same ID passed to [processChunk].
  void Function(String chunkId)? onChunkProcessed;

  // Worker isolate communication
  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  ReceivePort? _mainReceivePort;
  StreamSubscription? _mainReceiveSubscription;
  Completer<void>? _initCompleter;
  Completer<void>? _flushCompleter;

  // --- Circuit breaker ---
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 5;
  bool _circuitOpen = false;

  // --- Pending chunk queue (buffers during worker spawn) ---
  final List<_PendingChunk> _pendingChunks = [];
  static const int _maxPendingChunks = 12; // 60s of audio (12 × 5s chunks)

  // --- Heartbeat ---
  Timer? _heartbeatTimer;
  DateTime? _lastPong;
  bool _isRespawning = false;
  static const Duration _heartbeatInterval = Duration(seconds: 10);
  static const Duration _heartbeatTimeout = Duration(seconds: 15);

  // --- Streaming fast path state ---
  /// Last endTime (seconds) emitted by a streaming segment. Downstream
  /// (ChunkQueueManager) uses this to skip chunks whose audio was already
  /// covered by streaming when falling back to chunk-based decode.
  double _streamingWatermark = 0.0;

  /// Whether the streaming path is currently considered healthy.
  /// Becomes false when: heartbeat fails, circuit breaker opens, or VAD is
  /// active but no stream_result arrives for [_streamingStallTimeout].
  bool _isStreamingHealthy = true;

  /// Most recent wall-clock time a stream_result arrived (for stall detection).
  DateTime? _lastStreamResultAt;

  /// Most recent VAD state seen from the worker. The watchdog only fires when
  /// VAD is active — silence is legitimately quiet.
  bool _vadActive = false;

  /// Watchdog timer: fires every [_streamingWatchdogInterval] and checks
  /// whether streaming has gone quiet during active VAD.
  Timer? _streamingWatchdog;
  static const Duration _streamingWatchdogInterval = Duration(seconds: 10);
  static const Duration _streamingStallTimeout = Duration(seconds: 60);

  /// Invoked when [_isStreamingHealthy] transitions. The pipeline uses this
  /// to toggle [ChunkQueueManager] between stream-primary and chunk-primary
  /// processing modes.
  void Function(bool healthy, String reason)? onStreamingHealthChanged;

  /// Current streaming watermark in seconds. Reset to 0 on connect.
  double get streamingWatermark => _streamingWatermark;

  /// Whether streaming is considered healthy right now.
  bool get isStreamingHealthy => _isStreamingHealthy;

  LocalSttSocket({
    required String? modelPath,
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

  @override
  PureSocketStatus get status => _status;

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    if (_status == PureSocketStatus.connecting ||
        _status == PureSocketStatus.connected) {
      return false;
    }

    _status = PureSocketStatus.connecting;

    if (_modelPath == null || _modelPath!.isEmpty) {
      debugPrint(
          '[LocalSttSocket] ERROR: model path is null/empty, cannot connect');
      _status = PureSocketStatus.notConnected;
      return false;
    }

    try {
      // Set up communication channel
      _mainReceivePort = ReceivePort();
      _mainReceiveSubscription =
          _mainReceivePort!.listen(_handleWorkerMessage);

      // Spawn worker isolate
      _workerIsolate = await Isolate.spawn(
        workerEntryPoint,
        _mainReceivePort!.sendPort,
        debugName: 'local-stt-worker',
      );

      // Wait for worker's SendPort (first message in handshake)
      final handshakeCompleter = Completer<SendPort>();
      _initCompleter = Completer<void>();

      // Replace listener temporarily to capture the handshake
      _mainReceiveSubscription!.onData((message) {
        if (message is SendPort) {
          handshakeCompleter.complete(message);
          // Restore normal message handling
          _mainReceiveSubscription!.onData(_handleWorkerMessage);
        }
      });

      _workerSendPort = await handshakeCompleter.future
          .timeout(const Duration(seconds: 10));

      // Initialize engine in worker
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

      // Wait for 'ready' response
      await _initCompleter!.future.timeout(const Duration(seconds: 30));
      _initCompleter = null;

      _status = PureSocketStatus.connected;
      _circuitOpen = false;
      _consecutiveErrors = 0;
      // Reset streaming state and mark healthy on a fresh worker. The first
      // stream_result (or stall) will confirm or revoke this optimistic state.
      _streamingWatermark = 0.0;
      _lastStreamResultAt = null;
      _vadActive = false;
      _setStreamingHealth(true, 'connected');
      _startHeartbeat();
      _startStreamingWatchdog();
      onConnected();
      return true;
    } catch (e) {
      debugPrint('[LocalSttSocket] Connect failed: $e');
      _status = PureSocketStatus.notConnected;
      _cleanup();
      return false;
    }
  }

  /// Request the worker to process a chunk file from disk.
  ///
  /// Called by [ChunkQueueManager] when a chunk becomes pending.
  /// The worker reads the PCM16 file, decodes it, and responds with
  /// `['chunk_result', chunkId, jsonSegments?, vadActive]`.
  void processChunk(String filePath, String chunkId, double offsetSeconds) {
    // Circuit breaker: skip if too many consecutive errors
    if (_circuitOpen) {
      debugPrint('[LocalSttSocket] Circuit open, skipping chunk $chunkId');
      onChunkProcessed?.call(chunkId);
      return;
    }

    // Buffer chunks while worker is connecting/respawning
    if (_workerSendPort == null) {
      if (_pendingChunks.length >= _maxPendingChunks) {
        _pendingChunks.removeAt(0);
        debugPrint('[LocalSttSocket] Pending queue full, dropping oldest chunk');
      }
      _pendingChunks.add(_PendingChunk(filePath, chunkId, offsetSeconds));
      debugPrint('[LocalSttSocket] Worker not ready, queuing chunk $chunkId '
          '(${_pendingChunks.length} pending)');
      return;
    }

    _workerSendPort!.send(['process_chunk', filePath, chunkId, offsetSeconds]);
  }

  @override
  void send(dynamic message) {
    // Streaming fast path: forwards raw PCM16 bytes to the worker isolate for
    // memory-only VAD + decode. The worker replies with `stream_result` events
    // (see [_handleWorkerMessage]). Used by:
    //   - SpeechProfileProvider (voice enrollment)
    //   - TranscriptionPipeline dual-write (when `useStreamingPipeline` is on)
    if (_workerSendPort == null) return;
    if (message is Uint8List) {
      _workerSendPort!.send(['send_audio', message]);
    } else if (message is List<int>) {
      _workerSendPort!.send(['send_audio', Uint8List.fromList(message)]);
    }
  }

  /// Flush remaining VAD tail. Waits for worker to finish processing.
  Future<void> flushNow() async {
    if (_workerSendPort == null) return;

    _flushCompleter = Completer<void>();
    _workerSendPort!.send(['flush']);

    try {
      await _flushCompleter!.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      debugPrint('[LocalSttSocket] Flush timed out after 5s');
    } finally {
      _flushCompleter = null;
    }
  }

  @override
  Future disconnect() async {
    if (_status == PureSocketStatus.disconnected ||
        _status == PureSocketStatus.notConnected) {
      return;
    }

    // Flush VAD tail before disconnecting
    await flushNow();

    _stopHeartbeat();
    _stopStreamingWatchdog();
    _shutdownWorker();
    _status = PureSocketStatus.disconnected;
    debugPrint('[LocalSttSocket] Disconnected');
    onClosed();
  }

  @override
  Future stop() async {
    _stopHeartbeat();
    _stopStreamingWatchdog();
    _shutdownWorker();
    _status = PureSocketStatus.disconnected;
  }

  void _shutdownWorker() {
    _workerSendPort?.send(['shutdown']);

    // Safety net: kill isolate after a brief delay
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

  // ---------------------------------------------------------------------------
  // Heartbeat
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
      debugPrint('[LocalSttSocket] Worker heartbeat timeout — respawning');
      _respawnWorker();
    }
  }

  Future<void> _respawnWorker() async {
    if (_isRespawning) return;
    _isRespawning = true;
    _stopHeartbeat();
    _stopStreamingWatchdog();
    _setStreamingHealth(false, 'worker_respawn');
    debugPrint('[LocalSttSocket] Respawning worker isolate...');

    try {
      _workerIsolate?.kill(priority: Isolate.beforeNextEvent);
      _cleanup();
      _status = PureSocketStatus.notConnected;

      final success = await connect();
      if (success) {
        debugPrint('[LocalSttSocket] Worker respawned successfully');
      } else {
        debugPrint('[LocalSttSocket] Worker respawn failed');
        onError(Exception('Worker respawn failed'), StackTrace.current);
      }
    } catch (e) {
      debugPrint('[LocalSttSocket] Respawn error: $e');
      onError(
          e is Exception ? e : Exception(e.toString()), StackTrace.current);
    } finally {
      _isRespawning = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Streaming watchdog + health state
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

  /// Detects the "worker alive but not producing segments during speech" case.
  /// Heartbeat only catches a dead isolate; this catches a wedged one.
  void _checkStreamingStall() {
    if (!_vadActive) return; // silence is expected to be quiet
    if (_lastStreamResultAt == null) return;
    final stalled =
        DateTime.now().difference(_lastStreamResultAt!) > _streamingStallTimeout;
    if (stalled && _isStreamingHealthy) {
      debugPrint('[LocalSttSocket] Streaming stalled '
          '(no stream_result in ${_streamingStallTimeout.inSeconds}s with VAD active)');
      _setStreamingHealth(false, 'stream_stall');
    }
  }

  /// Transition streaming health and fire [onStreamingHealthChanged] if it
  /// actually changed. Reason is for logs/telemetry — callers should pass a
  /// short stable tag (e.g. 'worker_respawn', 'circuit_open', 'stream_stall').
  void _setStreamingHealth(bool healthy, String reason) {
    if (_isStreamingHealthy == healthy) return;
    _isStreamingHealthy = healthy;
    debugPrint(
        '[LocalSttSocket] Streaming health → ${healthy ? "HEALTHY" : "UNHEALTHY"} ($reason)');
    onStreamingHealthChanged?.call(healthy, reason);
  }

  // ---------------------------------------------------------------------------
  // Pending chunk queue
  // ---------------------------------------------------------------------------

  void _drainPendingChunks() {
    if (_pendingChunks.isEmpty) return;
    debugPrint(
        '[LocalSttSocket] Draining ${_pendingChunks.length} pending chunks');
    final chunks = List<_PendingChunk>.from(_pendingChunks);
    _pendingChunks.clear();
    for (final pending in chunks) {
      processChunk(pending.filePath, pending.chunkId, pending.offsetSeconds);
    }
  }

  // ---------------------------------------------------------------------------
  // Message handling
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
        debugPrint('[LocalSttSocket] Worker error: $errorMsg');
        final trace = stackStr != null
            ? StackTrace.fromString(stackStr)
            : StackTrace.current;

        // Circuit breaker: track consecutive errors
        _consecutiveErrors++;
        if (_consecutiveErrors >= _maxConsecutiveErrors && !_circuitOpen) {
          _circuitOpen = true;
          debugPrint('[LocalSttSocket] Circuit breaker OPEN '
              'after $_consecutiveErrors consecutive errors');
          // Circuit opening means downstream can't trust streaming any more —
          // pipeline will switch to chunk-primary mode on this signal.
          _setStreamingHealth(false, 'circuit_open');
        }

        onError(Exception(errorMsg), trace);
        // If init was pending, fail it
        if (_initCompleter != null && !_initCompleter!.isCompleted) {
          _initCompleter!.completeError(Exception(errorMsg));
        }

      case 'chunk_result':
        final chunkId = message.length > 1 ? message[1] as String : '';
        final segments = _extractSegments(message, 2);
        final vadActive =
            message.length > 3 ? message[3] as bool : false;

        // Reset circuit breaker on successful decode
        if (segments != null) {
          _consecutiveErrors = 0;
          // Bridge: TranscripSegmentSocketService.onMessage still expects a
          // JSON string. Removed when LocalSttSocket is deleted (Commit 6).
          onMessage(jsonEncode(segments));
        }

        // Notify VAD state
        onVadStateChanged?.call(vadActive);

        // Notify chunk completion (so ChunkQueueManager can proceed)
        onChunkProcessed?.call(chunkId);

      case 'stream_result':
        // Streaming fast path: memory-only audio decoded without disk I/O.
        final segments = _extractSegments(message, 1);
        final vadActive =
            message.length > 2 ? message[2] as bool : false;

        // Always bump the stall timestamp — even empty results from the worker
        // count as "worker is alive and keeping up".
        _lastStreamResultAt = DateTime.now();
        _vadActive = vadActive;

        if (segments != null) {
          _consecutiveErrors = 0;
          _streamingWatermark =
              _maxEndTimeFromMaps(segments, _streamingWatermark);
          onMessage(jsonEncode(segments));
        }
        // Any successful worker response confirms streaming is healthy again,
        // which is how we auto-recover after a transient stall or respawn.
        if (!_isStreamingHealthy) {
          _setStreamingHealth(true, 'stream_result_ok');
        }
        onVadStateChanged?.call(vadActive);

      case 'flushed':
        final segments = _extractSegments(message, 1);
        if (segments != null) {
          onMessage(jsonEncode(segments));
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

  /// Normalize the worker's segment payload at the given index of the
  /// message. After the Commit-2 protocol change segments arrive as
  /// `List<Map<String, Object?>>`. Returns null if nothing is there.
  List<Map<String, Object?>>? _extractSegments(List<dynamic> message, int at) {
    if (message.length <= at) return null;
    final raw = message[at];
    if (raw == null) return null;
    if (raw is List) {
      return raw.whereType<Map>().map((m) => m.cast<String, Object?>()).toList();
    }
    return null;
  }

  /// Max `end` across segment maps, clamped to never decrease below [current].
  double _maxEndTimeFromMaps(
      List<Map<String, Object?>> segments, double current) {
    var best = current;
    for (final item in segments) {
      final end = item['end'];
      if (end is num && end.toDouble() > best) {
        best = end.toDouble();
      }
    }
    return best;
  }

  @override
  void onMessage(dynamic message) {
    _listener?.onMessage(message);
  }

  @override
  void onConnected() {
    _listener?.onConnected();
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    _listener?.onClosed(closeCode);
  }

  @override
  void onError(Object err, StackTrace trace) {
    debugPrint('[LocalSttSocket] Error: $err');
    _listener?.onError(err, trace);
  }

  @override
  void onConnectionStateChanged(bool isConnected) {
    // No-op: local STT does not depend on network connectivity.
  }
}
