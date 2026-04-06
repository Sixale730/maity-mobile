import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/local_stt_worker.dart';
import 'package:omi/services/sockets/pure_socket.dart';

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
class LocalSttSocket implements IPureSocket {
  PureSocketStatus _status = PureSocketStatus.notConnected;
  IPureSocketListener? _listener;
  final String? _modelPath;
  final String? _speakerModelPath;
  final Uint8List? _userEmbeddingBytes;
  final LocalSttModelType _modelType;
  final double? _maxSpeechDuration;
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

  LocalSttSocket({
    required String? modelPath,
    LocalSttModelType modelType = LocalSttModelType.parakeet,
    String? speakerModelPath,
    Uint8List? userEmbeddingBytes,
    double? maxSpeechDuration,
    String? acousticProfileJson,
  })  : _modelPath = modelPath,
        _modelType = modelType,
        _speakerModelPath = speakerModelPath,
        _userEmbeddingBytes = userEmbeddingBytes,
        _maxSpeechDuration = maxSpeechDuration,
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
        _acousticProfileJson,
      ]);

      // Wait for 'ready' response
      await _initCompleter!.future.timeout(const Duration(seconds: 30));
      _initCompleter = null;

      _status = PureSocketStatus.connected;
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
    if (_workerSendPort == null) {
      debugPrint('[LocalSttSocket] Cannot process chunk: worker not connected');
      return;
    }
    _workerSendPort!.send(['process_chunk', filePath, chunkId, offsetSeconds]);
  }

  @override
  void send(dynamic message) {
    // For chunk-based recording (TranscriptionPipeline), audio is routed to
    // AudioChunkWriter before reaching this method — so send() is never called.
    // For speech profile enrollment (SpeechProfileProvider), audio is sent
    // directly here. Forward to the worker isolate for streaming decode.
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

    _shutdownWorker();
    _status = PureSocketStatus.disconnected;
    debugPrint('[LocalSttSocket] Disconnected');
    onClosed();
  }

  @override
  Future stop() async {
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
  }

  void _handleWorkerMessage(dynamic message) {
    if (message is! List || message.isEmpty) return;

    final type = message[0] as String;
    switch (type) {
      case 'ready':
        _initCompleter?.complete();

      case 'error':
        final errorMsg = message.length > 1 ? message[1] as String : 'Unknown';
        final stackStr = message.length > 2 ? message[2] as String? : null;
        debugPrint('[LocalSttSocket] Worker error: $errorMsg');
        final trace = stackStr != null
            ? StackTrace.fromString(stackStr)
            : StackTrace.current;
        onError(Exception(errorMsg), trace);
        // If init was pending, fail it
        if (_initCompleter != null && !_initCompleter!.isCompleted) {
          _initCompleter!.completeError(Exception(errorMsg));
        }

      case 'chunk_result':
        final chunkId = message.length > 1 ? message[1] as String : '';
        final jsonSegments =
            message.length > 2 ? message[2] as String? : null;
        final vadActive =
            message.length > 3 ? message[3] as bool : false;

        // Forward decoded segments to pipeline (same path as before)
        if (jsonSegments != null) {
          onMessage(jsonSegments);
        }

        // Notify VAD state
        onVadStateChanged?.call(vadActive);

        // Notify chunk completion (so ChunkQueueManager can proceed)
        onChunkProcessed?.call(chunkId);

      case 'flushed':
        if (message.length > 1 && message[1] is String) {
          onMessage(message[1]);
        }
        _flushCompleter?.complete();

      case 'vad_state':
        if (message.length > 1) {
          onVadStateChanged?.call(message[1] as bool);
        }
    }
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
