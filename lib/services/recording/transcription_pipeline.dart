import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/stt/local/device_memory_service.dart';
import 'package:omi/services/stt/local/audio_chunk_writer.dart';
import 'package:omi/services/stt/local/chunk_queue_manager.dart';
import 'package:omi/services/stt/local/local_stt_model_type.dart';
import 'package:omi/services/stt/local/model_download_service.dart';
import 'package:omi/services/stt/cloud/cloud_stt_orchestrator.dart';
import 'package:omi/services/stt/local/local_stt_engine_service.dart';
import 'dart:io' show File;
import 'package:omi/services/recording/telemetry_collector.dart';
import 'package:omi/services/recording/ui_segment_controller.dart';
import 'package:omi/services/recording/wav_backup_service.dart';
import 'package:omi/services/notifications/notification_service.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart';
import 'package:omi/services/vad/vad_service.dart';
import 'package:omi/services/vad/vad_state.dart';
import 'package:omi/services/vad/vad_metrics.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';

/// Callback for when new segments are received.
typedef OnSegmentsReceived = void Function(List<TranscriptSegment> newSegments);

/// Callback for when a message event is received from the socket.
typedef OnMessageEvent = void Function(MessageEvent event);

/// Callback for when connection is lost and auto-finalize is needed.
typedef OnAutoFinalizeNeeded = Future<void> Function();

/// Callback to notify listeners (typically CaptureProvider.notifyListeners).
typedef OnNotifyListeners = void Function();

/// Manages the transcription socket lifecycle, segment buffering,
/// health monitoring, keep-alive reconnection, and VAD integration.
///
/// This service does NOT directly call persistence or recovery services.
/// Those are PersistenceManager's responsibility and are triggered via
/// the [onSegmentsReceived] callback.
class TranscriptionPipeline implements ITransctiptSegmentSocketServiceListener {
  /// Cloud STT transport (Deepgram / Gemini WebSocket). Null when the active
  /// provider is on-device. Owns the socket, WAL capture, timestamp offset,
  /// and reconnect buffer.
  CloudSttOrchestrator? _cloudOrchestrator;

  /// Convenience accessor: the underlying socket while cloud STT is active.
  TranscriptSegmentSocketService? get _socket => _cloudOrchestrator?.socket;

  /// Local STT worker service (Parakeet / Moonshine / Canary). Null when
  /// cloud STT is active. Exposes typed callbacks so segments flow straight
  /// into [_onLocalSegments] without a JSON string round-trip.
  LocalSttEngineService? _localEngine;

  /// Cached codec from the most recent [initiateWebsocket] call. The cloud
  /// socket used to expose it via `_socket.codec`, but when local STT is
  /// active there is no socket — [_initChunkPipeline] reads this instead so
  /// it can configure the audio transcoder.
  BleAudioCodec? _currentCodec;

  // Keep-alive + token refresh: owned by [CloudSttOrchestrator].

  // ---------------------------------------------------------------------------
  // Health monitor
  // ---------------------------------------------------------------------------
  Timer? _socketHealthTimer;
  DateTime? _lastSegmentReceivedAt;
  int _sttReconnectAttempts = 0;
  static const int _maxSttReconnectAttempts = 3;
  DateTime? _lastAudioBytesSentAt;

  // BLE devices always send audio bytes (even silence), so the
  // audio-flowing check in _onSilenceTimeout doesn't apply to them.
  bool _isBleSource = false;

  /// Set whether audio comes from a BLE device (always sends bytes, even silence).
  void setBleSource(bool value) {
    _isBleSource = value;
  }

  // ---------------------------------------------------------------------------
  // Silence timer
  // ---------------------------------------------------------------------------
  Timer? _silenceTimer;

  // ---------------------------------------------------------------------------
  // Segment notification coalescing (frame-aware)
  // ---------------------------------------------------------------------------
  bool _segmentNotifyPending = false;
  bool _segmentFrameInFlight = false;

  // ---------------------------------------------------------------------------
  // Segments state
  // ---------------------------------------------------------------------------
  List<TranscriptSegment> segments = [];
  int _segmentsVersion = 0;
  int get segmentsVersion => _segmentsVersion;
  bool hasTranscripts = false;

  // ---------------------------------------------------------------------------
  // Chunk-based local STT (log-structured processing)
  // ---------------------------------------------------------------------------
  AudioChunkWriter? _chunkWriter;
  WavBackupService? _wavBackupService;
  UISegmentController? _segmentController;

  /// Audio transcoder for non-PCM16 codecs (e.g., Opus from BLE/OMI devices).
  /// Decodes to PCM16 before writing to chunk writer. Null for PCM16 (no-op).
  IAudioTranscoder? _audioTranscoder;

  /// VAD activity indicator — replaces preview text.
  /// True when the worker's VAD detects active speech.
  final ValueNotifier<bool> vadSpeechActive = ValueNotifier(false);

  /// Segments from the bounded UISegmentController (local STT) or the
  /// unbounded list (cloud STT) for display.
  List<TranscriptSegment> get displaySegments =>
      _segmentController?.displaySegments ?? segments;

  /// Whether the chunk pipeline has audio data that hasn't been decoded yet.
  /// Used to prevent premature cancel when back is pressed before first segment.
  bool get hasUnprocessedAudio =>
      _chunkWriter != null && _chunkWriter!.chunksWritten > 0;

  /// Whether archived pages are available for scroll-up pagination.
  bool get hasArchivedPages => _segmentController?.hasArchivedPages ?? false;

  /// Load an archived page of segments (for scroll-up pagination).
  Future<List<TranscriptSegment>> loadArchivedPage(int pageIndex) =>
      _segmentController?.loadPage(pageIndex) ?? Future.value([]);

  // ---------------------------------------------------------------------------
  // Connection state
  // ---------------------------------------------------------------------------
  bool _isConnected = true;
  bool get isConnected => _isConnected;

  // ---------------------------------------------------------------------------
  // Socket state
  // ---------------------------------------------------------------------------
  bool _transcriptServiceReady = false;
  SttProvider? _activeSttProvider;
  bool get _isLocalStt =>
      _activeSttProvider == SttProvider.localParakeet ||
      _activeSttProvider == SttProvider.localMoonshine ||
      _activeSttProvider == SttProvider.localCanary;

  /// Whether a given provider is a local on-device STT.
  static bool _isLocalSttProvider(SttProvider? p) =>
      p == SttProvider.localParakeet ||
      p == SttProvider.localMoonshine ||
      p == SttProvider.localCanary;

  /// Map a LocalSttModelType to its corresponding SttProvider.
  static SttProvider _providerForModelType(LocalSttModelType type) {
    switch (type) {
      case LocalSttModelType.moonshine:
        return SttProvider.localMoonshine;
      case LocalSttModelType.canary:
        return SttProvider.localCanary;
      case LocalSttModelType.parakeet:
        return SttProvider.localParakeet;
    }
  }

  /// Pick the best available local STT provider (user's preferred first).
  static SttProvider? _bestLocalSttProvider() {
    final activeModel = LocalSttModelType.fromString(
        SharedPreferencesUtil().activeLocalSttModel);
    if (ModelDownloadService.instance.isModelReadyFor(activeModel)) {
      return _providerForModelType(activeModel);
    }
    // Preferred not ready — use whichever is available
    for (final type in LocalSttModelType.values) {
      if (ModelDownloadService.instance.isModelReadyFor(type)) {
        return _providerForModelType(type);
      }
    }
    return null;
  }

  /// The STT provider currently being used for transcription.
  SttProvider? get activeSttProvider => _activeSttProvider;

  bool get transcriptServiceReady =>
      _transcriptServiceReady && (_isConnected || _isLocalStt);

  /// Access the underlying socket for sending audio bytes.
  TranscriptSegmentSocketService? get socket => _socket;

  // ---------------------------------------------------------------------------
  // Cloud-only state — owned by [_cloudOrchestrator]. These accessors keep
  // the pipeline's internal code readable; mutations delegate to the
  // orchestrator. For local STT all of these are null/zero.
  // ---------------------------------------------------------------------------
  bool get walEnabled => _cloudOrchestrator?.walEnabled ?? false;
  void setWalEnabled(bool enabled) =>
      _cloudOrchestrator?.setWalEnabled(enabled);

  Duration get _cumulativeOffset =>
      _cloudOrchestrator?.cumulativeOffset ?? Duration.zero;

  // ---------------------------------------------------------------------------
  // Reconnection flags
  // ---------------------------------------------------------------------------
  bool _isReconnecting = false;
  bool _isReconnectingSocket = false;
  bool get isReconnectingSocket => _isReconnectingSocket;

  // ---------------------------------------------------------------------------
  // Message event statuses
  // ---------------------------------------------------------------------------
  List<MessageEvent> _transcriptionServiceStatuses = [];
  List<MessageEvent> get transcriptionServiceStatuses =>
      _transcriptionServiceStatuses;

  // ---------------------------------------------------------------------------
  // VAD
  // ---------------------------------------------------------------------------
  VadService? _vadService;
  VadMetrics? get vadMetrics => _vadService?.getMetricsSnapshot();
  bool get isVadActive => _vadService != null && _vadService!.isInitialized;
  final ValueNotifier<VadState?> vadStateNotifier = ValueNotifier(null);

  // ---------------------------------------------------------------------------
  // Audio buffer limit (M3 bug fix)
  // ---------------------------------------------------------------------------
  /// Maximum audio buffer bytes (~5 seconds at 16kHz PCM16).
  static const int maxAudioBufferBytes = 160000;

  // Reconnect audio buffer is owned by [CloudSttOrchestrator]; reached via
  // [_cloudOrchestrator?.bufferAudioFrame] / [drainReconnectBuffer].

  // ---------------------------------------------------------------------------
  // WS bytes sent counter (exposed for CaptureProvider metrics)
  // ---------------------------------------------------------------------------
  int wsSocketBytesSent = 0;

  // ---------------------------------------------------------------------------
  // Callbacks
  // ---------------------------------------------------------------------------
  OnSegmentsReceived? onSegmentsReceived;
  OnMessageEvent? onMessageEvent;
  OnAutoFinalizeNeeded? onAutoFinalizeNeeded;
  OnNotifyListeners? onNotifyListeners;

  /// Callback for scheduling work after the current frame is painted.
  /// Set by CaptureProvider to bridge WidgetsBinding.addPostFrameCallback.
  void Function(VoidCallback)? onSchedulePostFrame;

  /// Called on silence timeout to let CaptureProvider decide what to do.
  VoidCallback? onSilenceTimeout;

  /// Called when transcription stalls (no segments for >60s) and needs
  /// socket reconnection. Returns the params needed to reconnect.
  Future<void> Function()? onTranscriptionStalled;

  CaptureLogService get _captureLog => CaptureLogService.instance;

  // ---------------------------------------------------------------------------
  // Socket lifecycle
  // ---------------------------------------------------------------------------

  /// Create or reconnect the transcription socket.
  Future<void> initiateWebsocket({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    bool force = false,
    String? source,
  }) async {
    Logger.debug('initiateWebsocket in TranscriptionPipeline');
    _currentCodec = audioCodec;

    // Update timestamp offset on reconnection (not first connection)
    if (_cloudOrchestrator?.recordingStartTime != null) {
      _updateTimestampOffset();
      TelemetryCollector.instance.recordReconnection(reason: source);
    }

    BleAudioCodec codec = audioCodec;
    sampleRate ??= mapCodecToSampleRate(codec);
    channels ??= (codec == BleAudioCodec.pcm16 || codec == BleAudioCodec.pcm8)
        ? 1
        : 2;

    Logger.debug(
        'Initiating WebSocket with: codec=$codec, sampleRate=$sampleRate, channels=$channels, isPcm=$isPcm');

    // Get language and custom STT config
    String language = SharedPreferencesUtil().hasSetPrimaryLanguage
        ? SharedPreferencesUtil().userPrimaryLanguage
        : "multi";
    final customSttConfig = SharedPreferencesUtil().customSttConfig;

    Logger.debug(
        'Custom STT enabled: ${customSttConfig.isEnabled}, provider: ${customSttConfig.provider}');
    if (customSttConfig.isEnabled) {
      debugPrint(
          '[Maity] STT key hash: ${customSttConfig.apiKey?.hashCode.toRadixString(16).padLeft(8, "0").substring(0, 8) ?? "null"}');
    }

    // Check codec compatibility for custom STT - fallback to default
    CustomSttConfig? effectiveConfig =
        customSttConfig.isEnabled ? customSttConfig : null;

    // Auto-fallback to local STT when offline and any model is ready
    if (effectiveConfig == null &&
        !ConnectivityService().isConnected &&
        SharedPreferencesUtil().localSttAutoFallback &&
        ModelDownloadService.instance.isAnyModelReady) {
      final fallbackProvider = _bestLocalSttProvider();
      if (fallbackProvider != null) {
        effectiveConfig = CustomSttConfig(provider: fallbackProvider);
        debugPrint(
            '[TranscriptionPipeline] Offline -> using local ${fallbackProvider.name}');
      }
    }

    // Fallback: if Omi backend URL is not configured, use Deepgram directly
    if (effectiveConfig == null) {
      final apiBaseUrl = Env.apiBaseUrl;
      if (apiBaseUrl == null || apiBaseUrl.isEmpty) {
        final deepgramKey = Env.deepgramApiKey;
        if (deepgramKey != null && deepgramKey.isNotEmpty) {
          debugPrint('[TranscriptionPipeline] API_BASE_URL empty, falling back to Deepgram Live');
          effectiveConfig = CustomSttConfig(
            provider: SttProvider.deepgramLive,
            apiKey: deepgramKey,
            language: language,
          );
        }
      }
    }

    // Enforce: non-admins cannot use cloud STT providers
    if (effectiveConfig != null && !_isLocalSttProvider(effectiveConfig.provider)) {
      final role = SharedPreferencesUtil().getString('cachedUserRole');
      if (role != 'admin') {
        debugPrint('[TranscriptionPipeline] Non-admin tried cloud STT (${effectiveConfig.provider}), forcing local');
        final fallbackProvider = _bestLocalSttProvider();
        effectiveConfig = fallbackProvider != null
            ? CustomSttConfig(provider: fallbackProvider)
            : null;
      }
    }

    if (effectiveConfig != null &&
        effectiveConfig.provider != SttProvider.localParakeet &&
        effectiveConfig.provider != SttProvider.localMoonshine &&
        !TranscriptSocketServiceFactory.isCodecSupportedForCustomStt(codec)) {
      debugPrint('[CustomSTT] Codec $codec not supported, falling back to Omi');
      effectiveConfig = null;
    }

    _captureLog.log('socket', 'websocket_initiating', details: {
      'codec': codec.name,
      'sample_rate': sampleRate,
      'channels': channels,
      'custom_stt': effectiveConfig != null,
      'language': language,
      'force': force,
      'source': source,
    });

    // Local STT branch: skip the cloud socket abstraction entirely and drive
    // the worker isolate via [LocalSttEngineService]. Segments come back as
    // typed `List<TranscriptSegment>` — no WebSocket, no jsonDecode chain.
    if (effectiveConfig != null &&
        _isLocalSttProvider(effectiveConfig.provider)) {
      final engine = _createLocalEngineFromConfig(effectiveConfig.provider);
      if (engine == null) {
        _captureLog.log('socket', 'local_stt_init_failed',
            severity: 'error',
            details: {'provider': effectiveConfig.provider.name});
        return;
      }
      _wireLocalEngineCallbacks(engine);
      final ok = await engine.connect();
      if (!ok) {
        debugPrint('[TranscriptionPipeline] LocalSttEngineService connect failed');
        _captureLog.log('socket', 'local_stt_connect_failed', severity: 'error');
        return;
      }
      _localEngine = engine;
      _transcriptServiceReady = true;
      _activeSttProvider = effectiveConfig.provider;
      TelemetryCollector.instance.setSttProvider(_activeSttProvider?.name);
      // Local STT never uses WAL — the orchestrator isn't created for this
      // session, so walEnabled defaults to false.
      await _initChunkPipeline();
      return;
    }

    // Cloud STT branch: build the orchestrator and connect.
    final orchestrator = CloudSttOrchestrator(
      captureLog: _captureLog,
      onRawMessage: (_) {}, // wired in a later commit
      onSocketConnected: onConnected,
      onSocketClosed: onClosed,
      onSocketError: (err, _) => onError(err),
      onTranscriptionStalled: () => onTranscriptionStalled?.call(),
      onAutoFinalize: () => onAutoFinalizeNeeded?.call() ?? Future.value(),
      onMessageEventReceived: (event) => onMessageEventReceived(event),
      onNotifyListeners: () => onNotifyListeners?.call(),
    );

    final connected = await orchestrator.connect(
      codec: codec,
      sampleRate: sampleRate,
      language: language,
      force: force,
      source: source,
      customSttConfig: effectiveConfig,
    );
    if (!connected) {
      // Cloud failed. Fall back to local STT if any model is ready. This used
      // to route through the factory, but local STT now bypasses it entirely
      // — we build a LocalSttEngineService directly here.
      await orchestrator.dispose();
      if (ModelDownloadService.instance.isAnyModelReady) {
        final fallbackProvider = _bestLocalSttProvider();
        if (fallbackProvider != null) {
          debugPrint(
              '[TranscriptionPipeline] Cloud failed, falling back to local ${fallbackProvider.name}');
          final engine = _createLocalEngineFromConfig(fallbackProvider);
          if (engine != null) {
            _wireLocalEngineCallbacks(engine);
            if (await engine.connect()) {
              _localEngine = engine;
              _transcriptServiceReady = true;
              _activeSttProvider = fallbackProvider;
              TelemetryCollector.instance
                  .setSttProvider(_activeSttProvider?.name);
              await _initChunkPipeline();
              return;
            }
          }
          debugPrint('[TranscriptionPipeline] Local fallback also failed');
          _captureLog.log('socket', 'local_stt_init_failed', severity: 'error');
          return;
        }
      }
      _startKeepAlive();
      return;
    }

    _cloudOrchestrator = orchestrator;
    // Pipeline stays subscribed as the ITransctiptSegmentSocketServiceListener
    // for now; the orchestrator will take ownership of the subscription in a
    // later commit once the listener methods move too.
    _socket?.subscribe(this, this);
    _transcriptServiceReady = true;
    _activeSttProvider = effectiveConfig?.provider ?? SttProvider.deepgramLive;
    TelemetryCollector.instance.setSttProvider(_activeSttProvider?.name);

    // Track recording start time for timestamp offset calculation.
    // Token refresh is scheduled internally by orchestrator.connect().
    orchestrator.markRecordingStartIfNeeded();

    // Initialize VAD if enabled and using custom STT with PCM16 codec
    await initializeVadService(codec, effectiveConfig);

    onNotifyListeners?.call();
  }

  /// Set the reconnecting flag to suppress keep-alive during intentional
  /// socket stop+restart cycles (e.g. resume from background, stall recovery).
  void setReconnecting(bool value) {
    _isReconnecting = value;
  }

  /// Stop the socket cleanly.
  Future<void> stopSocket(String reason) async {
    _cloudOrchestrator?.setBufferingForReconnect(true);
    // Mark the start of an audio-gap window. The window is closed in
    // _replayReconnectBuffer() (after reconnect) or in markStopped()
    // (when the user actually stops the recording).
    TelemetryCollector.instance.beginAudioGap();
    _captureLog.log('socket', 'socket_stopping',
        details: {'reason': reason});
    await _cloudOrchestrator?.disconnect(reason: reason);
    await _cloudOrchestrator?.dispose();
    _cloudOrchestrator = null;
    _transcriptServiceReady = false;

    // Clean up chunk pipeline so next session creates fresh instances.
    // Without this, _initChunkPipeline sees _chunkWriter != null and takes
    // the reconnect path with stale state instead of creating a new session.
    await _chunkWriter?.dispose();
    _chunkWriter = null;
    await _wavBackupService?.stop();
    _wavBackupService = null;
    _segmentController?.dispose();
    _segmentController = null;
    _audioTranscoder = null;
  }

  /// Updates the cumulative timestamp offset based on elapsed recording time.
  /// Called before reconnecting the cloud socket so new Deepgram segments
  /// (which restart at t=0) are shifted to the correct position in the
  /// timeline. No-op when local STT is active.
  void _updateTimestampOffset() {
    _cloudOrchestrator?.updateTimestampOffsetOnReconnect();
  }

  /// Resets the timestamp offset state. Called when recording fully stops.
  void resetTimestampOffset() {
    _cloudOrchestrator?.resetTimestampOffset();
  }

  /// Send raw bytes to the socket (used by AudioTransportService).
  ///
  /// For local STT: routes to [AudioChunkWriter] which buffers and writes to
  /// disk every 5 seconds. The worker pulls chunks from disk via
  /// [ChunkQueueManager].
  ///
  /// For cloud STT: sends directly to the WebSocket (unchanged behavior).
  /// WAL captures all audio frames; only marks as synced what the socket received.
  void sendToSocket(dynamic data) {
    // Local STT: route to chunk writer (audio goes to disk, not socket).
    // Transcode if needed (e.g., Opus from BLE/OMI → PCM16 for VAD + decode).
    if (_isLocalStt && _chunkWriter != null && data is List<int>) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      Uint8List pcmBytes;
      try {
        pcmBytes = _audioTranscoder != null ? _audioTranscoder!.transcode(bytes) : bytes;
      } catch (e) {
        debugPrint('[TranscriptionPipeline] Transcode error, skipping chunk: $e');
        return;
      }
      if (pcmBytes.isEmpty) return;
      // Chunk writer = crash-safety backup on disk. Always on.
      _chunkWriter!.addBytes(pcmBytes);
      _wavBackupService?.writeAudio(pcmBytes);
      // Streaming fast path: push PCM directly to the worker isolate for
      // low-latency in-memory decode. Gated by the kill-switch flag so we can
      // disable it in Developer Settings without redeploy.
      if (SharedPreferencesUtil().useStreamingPipeline) {
        _localEngine?.pushAudio(pcmBytes);
      }
      return;
    }

    // Cloud STT path: the orchestrator handles WAL capture, socket send,
    // and reconnect buffering. Pipeline only layers WAV backup on top since
    // that's a shared concern (both local and cloud write WAV).
    if (_wavBackupService != null && data is List<int>) {
      _wavBackupService!
          .writeAudio(data is Uint8List ? data : Uint8List.fromList(data));
    }
    _cloudOrchestrator?.sendAudio(data);
  }

  // ---------------------------------------------------------------------------
  // Chunk pipeline setup (local STT only)
  // ---------------------------------------------------------------------------

  /// Session ID for the current chunk pipeline. Set by CaptureProvider.
  String? chunkSessionId;

  /// Initialize chunk writer + queue manager for local STT.
  ///
  /// On reconnect (when `_chunkWriter` already exists), only re-wires the new
  /// socket's callbacks and resumes queue processing — does NOT recreate the
  /// writer, segment controller, or session, which would destroy accumulated
  /// transcription state.
  Future<void> _initChunkPipeline() async {
    if (chunkSessionId == null) {
      debugPrint('[TranscriptionPipeline] WARNING: chunkSessionId not set, cannot init chunk pipeline');
      return;
    }

    final queueManager = ChunkQueueManager.instance;

    // --- Reconnect path: pipeline already exists, just re-wire socket ---
    if (_chunkWriter != null) {
      debugPrint('[TranscriptionPipeline] Chunk pipeline exists — re-wiring socket callbacks for reconnect');
      _wireChunkSocketCallbacks(queueManager);
      // Kick the queue in case there are pending chunks the old socket never processed.
      queueManager.processNextChunk(chunkSessionId);
      return;
    }

    // --- First-time path: create writer, controller, session ---
    await queueManager.initialize();
    queueManager.setMaxQueueSize(DeviceMemoryService.cachedQueueCap);
    final sessionDir = await queueManager.startSession(chunkSessionId!);

    // Create chunk writer that flushes to disk every 5s
    _chunkWriter = AudioChunkWriter(
      sessionId: chunkSessionId!,
      baseDir: sessionDir,
      onChunkWritten: (meta) => queueManager.enqueueChunk(meta),
    );
    _chunkWriter!.start();

    // Start WAV backup for this session (parallel to chunk writer)
    _wavBackupService = WavBackupService();
    await _wavBackupService!.start(chunkSessionId!);

    // Create audio transcoder for non-PCM16 codecs (BLE/OMI sends Opus).
    // For local STT the engine owns the worker directly (no _socket), so fall
    // back to the cached codec tracked at session start.
    final codec = _socket?.codec ?? _currentCodec ?? BleAudioCodec.pcm16;
    if (codec != BleAudioCodec.pcm16) {
      _audioTranscoder = AudioTranscoderFactory.createToRawPcm(
        sourceCodec: codec,
        sampleRate: 16000,
      );
      debugPrint('[TranscriptionPipeline] Audio transcoder: ${codec.name} → PCM16');
    } else {
      _audioTranscoder = null;
    }

    // Create bounded segment controller
    _segmentController = UISegmentController();
    _segmentController!.startSession(chunkSessionId!, sessionDir);

    // Wire queue manager → socket → worker
    _wireChunkSocketCallbacks(queueManager);

    debugPrint('[TranscriptionPipeline] Chunk pipeline initialized for session $chunkSessionId');
  }

  /// Wire ChunkQueueManager ↔ LocalSttEngineService callbacks.
  /// Shared by first-init and reconnect paths.
  void _wireChunkSocketCallbacks(ChunkQueueManager queueManager) {
    final engine = _localEngine;
    if (engine == null) return;

    // Queue has a chunk ready → worker processes it.
    queueManager.onProcessChunk = (chunk) {
      engine.processChunkFile(
        chunk.filePath,
        '${chunk.sessionId}_${chunk.sequence}',
        chunk.offsetSeconds,
      );
    };

    // Worker finished a chunk → mark it completed in the queue.
    engine.onChunkProcessed = (chunkId) {
      final parts = chunkId.split('_');
      if (parts.length >= 2) {
        final seq = int.tryParse(parts.last);
        final sessionId = parts.sublist(0, parts.length - 1).join('_');
        if (seq != null) {
          queueManager.markCompleted(sessionId, seq);
        }
      }
      // Silence timer NOT reset here — only resets on speech detection.
    };

    // VAD callback is already wired via _wireLocalEngineCallbacks, but
    // re-wire here on reconnect paths in case the engine was replaced.
    engine.onVadStateChanged = onVadStateChanged;

    // Toggle queue mode when streaming health changes.
    // Healthy → stream-primary: new chunks accumulate as disk backup only.
    // Unhealthy → chunk-primary: drain backlog after the streaming watermark
    // so the user still gets transcription while we wait for streaming to
    // auto-recover on the next successful stream_result.
    final streamingOn = SharedPreferencesUtil().useStreamingPipeline;
    if (streamingOn) {
      queueManager.switchMode(ChunkProcessingMode.streamPrimary);
      TelemetryCollector.instance.recordStreamingEvent('streaming_started');
    }
    engine.onStreamingHealthChanged = (healthy, reason) {
      debugPrint(
          '[TranscriptionPipeline] Streaming health: $healthy ($reason)');
      DebugLogManager.logEvent('streaming_health_changed', {
        'healthy': healthy,
        'reason': reason,
        'watermark_sec': engine.streamingWatermark,
      });
      TelemetryCollector.instance.recordStreamingEvent(
        healthy ? 'streaming_recovered' : 'streaming_fallback',
        details: {
          'reason': reason,
          'watermark_sec': engine.streamingWatermark,
        },
      );
      if (!healthy) {
        queueManager.switchMode(
          ChunkProcessingMode.chunkPrimary,
          streamingWatermarkSec: engine.streamingWatermark,
          sessionId: chunkSessionId,
        );
      } else {
        queueManager.switchMode(ChunkProcessingMode.streamPrimary);
      }
    };
  }

  /// Flush the chunk writer (for app lifecycle pause).
  Future<void> flushChunkWriter({bool synchronous = false}) async {
    await _chunkWriter?.flush(synchronous: synchronous);
  }

  /// Update the last audio bytes sent timestamp (for STT stall detection).
  void updateLastAudioBytesSentAt() {
    _lastAudioBytesSentAt = DateTime.now();
  }

  // ---------------------------------------------------------------------------
  // VAD
  // ---------------------------------------------------------------------------

  /// Initialize VAD service if enabled and compatible.
  Future<void> initializeVadService(
      BleAudioCodec codec, CustomSttConfig? customSttConfig) async {
    await _vadService?.dispose();
    _vadService = null;
    vadStateNotifier.value = null;

    final vadConfig = SharedPreferencesUtil().vadConfig;

    if (!vadConfig.enabled) {
      debugPrint('[VAD] Disabled in settings');
      return;
    }

    if (customSttConfig == null || !customSttConfig.isEnabled) {
      debugPrint('[VAD] Custom STT not enabled, VAD requires direct transcription');
      return;
    }

    if (codec != BleAudioCodec.pcm16) {
      debugPrint('[VAD] Codec $codec not supported, VAD requires PCM16');
      return;
    }

    try {
      debugPrint('[VAD] Initializing VAD service...');
      _vadService = VadService(config: vadConfig);
      await _vadService!.initialize();

      _vadService!.onAudioToSend = (bytes) {
        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(bytes);
          wsSocketBytesSent += bytes.length;
        }
      };

      _vadService!.onStateChanged = (state) {
        debugPrint('[VAD] State changed: ${state.displayName}');
        vadStateNotifier.value = state;
      };

      debugPrint('[VAD] Service initialized successfully');
    } catch (e) {
      debugPrint('[VAD] Failed to initialize: $e');
      _vadService = null;
    }
  }

  /// Process audio frame through VAD (returns true if frame was sent).
  bool processVadFrame(Uint8List frame) {
    if (_vadService == null || !_vadService!.isInitialized) return false;
    return _vadService!.processAudioFrame(frame);
  }

  /// Flush VAD buffers (call when recording ends).
  void flushVad() {
    _vadService?.flush();
  }

  // ---------------------------------------------------------------------------
  // ITransctiptSegmentSocketServiceListener implementation
  // ---------------------------------------------------------------------------

  @override
  void onClosed([int? closeCode]) {
    _captureLog.log('socket', 'socket_closed', severity: 'warning', details: {
      'close_code': closeCode,
      'is_reconnecting': _isReconnecting,
    });
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;

    // Skip notifyListeners + keep-alive during intentional reconnection
    if (!_isReconnecting) {
      onNotifyListeners?.call();
      _startKeepAlive();
    }
  }

  @override
  void onError(Object err) {
    final errorStr = err.toString();

    // H4 bug fix: Categorize errors as terminal vs temporal
    if (errorStr.contains('Failed to find any displays') ||
        errorStr.contains('Permission denied') ||
        errorStr.contains('Invalid API key')) {
      _captureLog.log('socket', 'socket_error_terminal',
          severity: 'error', details: {'error': errorStr});
      TelemetryCollector.instance.recordError('socket_terminal', errorStr);
      _transcriptionServiceStatuses = [];
      _transcriptServiceReady = false;
      onNotifyListeners?.call();
      // Don't start keep-alive for terminal errors
      return;
    }

    // Temporal errors - attempt immediate reconnect, fall back to keep-alive
    _captureLog.log('socket', 'socket_error_temporal',
        severity: 'warning', details: {'error': errorStr});
    TelemetryCollector.instance.recordError('socket_temporal', errorStr);
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;
    onNotifyListeners?.call();

    // Try immediate reconnect; if it fails, fall back to keep-alive timer
    onTranscriptionStalled?.call();
  }

  @override
  void onConnected() {
    _captureLog.log('socket', 'socket_connected');
    _transcriptServiceReady = true;
    _cloudOrchestrator?.cancelKeepAlive();
    _replayReconnectBuffer();
    onNotifyListeners?.call();
  }

  /// Replay audio buffered during the reconnect gap, then clear the buffer.
  void _replayReconnectBuffer() {
    // Close any in-progress telemetry audio-gap window — the socket is back.
    TelemetryCollector.instance.endAudioGap();

    final orchestrator = _cloudOrchestrator;
    if (orchestrator == null) return;

    final buffered = orchestrator.drainReconnectBuffer();
    orchestrator.setBufferingForReconnect(false);

    if (buffered.isEmpty) return;

    for (final chunk in buffered) {
      _socket?.send(chunk);
    }
    debugPrint(
        '[TranscriptionPipeline] Replayed ${buffered.length} audio chunks after reconnect');
  }

  @override
  void onMessageEventReceived(MessageEvent event) {
    // Accumulate service status events locally
    if (event is MessageServiceStatusEvent) {
      _transcriptionServiceStatuses.add(event);
      _transcriptionServiceStatuses =
          List.from(_transcriptionServiceStatuses);
      onNotifyListeners?.call();
      return;
    }

    // Route all other events to CaptureProvider via callback
    onMessageEvent?.call(event);
  }

  @override
  void onSegmentReceived(List<TranscriptSegment> newSegments) {
    _processNewSegmentReceived(newSegments);
  }

  @override
  void onTerminalFailure(String reason) {
    _captureLog.log('socket', 'terminal_failure',
        severity: 'error', details: {'reason': reason});
    TelemetryCollector.instance.recordError('terminal_failure', reason);

    _transcriptServiceReady = false;

    // Cancel keep-alive and health monitor — the socket won't recover
    _cloudOrchestrator?.cancelKeepAlive();
    stopHealthMonitor();

    // Trigger auto-finalize to save whatever we have
    onAutoFinalizeNeeded?.call();

    onNotifyListeners?.call();
  }

  // ---------------------------------------------------------------------------
  // Segment processing
  // ---------------------------------------------------------------------------

  void _processNewSegmentReceived(List<TranscriptSegment> newSegments) {
    if (newSegments.isEmpty) return;

    // Apply cumulative offset for reconnection timestamp correction.
    // Cloud STT sessions restart at t=0; local STT chunks already have
    // absolute offsets applied by the worker, but reconnect offset still
    // applies if the socket was reconnected mid-recording.
    if (_cumulativeOffset > Duration.zero) {
      final offsetSeconds = _cumulativeOffset.inMilliseconds / 1000.0;
      for (final segment in newSegments) {
        segment.start += offsetSeconds;
        segment.end += offsetSeconds;
      }
    }

    assert(() {
      debugPrint(
          '[TranscriptionPipeline] Received ${newSegments.length} new segments, current total: ${segments.length}');
      return true;
    }());

    if (segments.isEmpty && (_segmentController?.activeSegments.isEmpty ?? true)) {
      _captureLog.log('segment', 'first_segment_received', details: {
        'new_count': newSegments.length,
      });
    }

    _captureLog.log('segment', 'segments_received',
        severity: 'debug',
        details: {
          'new_count': newSegments.length,
          'total': segments.length + newSegments.length,
        });

    // Route to UISegmentController (bounded, O(k)) or direct list (unbounded)
    if (_segmentController != null) {
      _segmentController!.addSegments(newSegments);
      _segmentsVersion = _segmentController!.version;
    } else {
      // Cloud STT path: unbounded list (existing behavior)
      final insertStartIndex = segments.length;
      final remainSegments =
          TranscriptSegment.updateSegments(segments, newSegments);
      segments.addAll(remainSegments);

      // Merge only at the boundary (O(k) instead of O(n^2))
      if (remainSegments.isNotEmpty) {
        TranscriptSegment.mergeNewSegmentsAtBoundary(segments,
            insertStartIndex: insertStartIndex);
      }
      _segmentsVersion++;
    }

    assert(() {
      debugPrint(
          '[TranscriptionPipeline] After update: ${displaySegments.length} display segments');
      return true;
    }());
    hasTranscripts = true;

    // Update health monitor timestamp
    _lastSegmentReceivedAt = DateTime.now();
    _sttReconnectAttempts = 0;

    // Reset silence timer (auto-save after N seconds of no speech)
    resetSilenceTimer();

    // Notify CaptureProvider to schedule saves (via callback)
    onSegmentsReceived?.call(newSegments);

    _notifySegmentUpdate();
  }

  /// Frame-aware notification coalescing for segment updates.
  /// Only dispatches a new notification after the previous frame has been
  /// painted, preventing rebuild backlog when render time exceeds the
  /// data arrival rate.
  void _notifySegmentUpdate() {
    _segmentNotifyPending = true;
    if (_segmentFrameInFlight) return;
    _dispatchSegmentNotification();
  }

  void _dispatchSegmentNotification() {
    if (!_segmentNotifyPending) return;
    _segmentNotifyPending = false;
    _segmentFrameInFlight = true;

    onNotifyListeners?.call();

    if (onSchedulePostFrame != null) {
      onSchedulePostFrame!(() {
        _segmentFrameInFlight = false;
        if (_segmentNotifyPending) {
          _dispatchSegmentNotification();
        }
      });
    } else {
      // Fallback if no post-frame scheduler is set
      _segmentFrameInFlight = false;
    }
  }

  void setHasTranscripts(bool value) {
    hasTranscripts = value;
  }

  // ---------------------------------------------------------------------------
  // VAD activity indicator (local STT)
  // ---------------------------------------------------------------------------

  /// Called by LocalSttSocket when the worker's VAD state transitions.
  void onVadStateChanged(bool isSpeechActive) {
    if (vadSpeechActive.value != isSpeechActive) {
      vadSpeechActive.value = isSpeechActive;
    }
  }

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------

  /// Start keep-alive timer (cloud STT only). No-op when local STT is active
  /// because the local worker never disappears from under us.
  void _startKeepAlive() => _cloudOrchestrator?.startKeepAlive();

  /// Start keep-alive timer (public entry point for delegate).
  void startKeepAlive() => _cloudOrchestrator?.startKeepAlive();

  /// Stop the keep-alive timer.
  void stopKeepAlive() => _cloudOrchestrator?.cancelKeepAlive();

  // ---------------------------------------------------------------------------
  // Health monitor
  // ---------------------------------------------------------------------------

  /// Start the socket health monitor to detect stalled transcription.
  void startHealthMonitor() {
    _socketHealthTimer?.cancel();
    _lastSegmentReceivedAt = null;

    _socketHealthTimer =
        Timer.periodic(const Duration(seconds: 10), (_) {
      _checkSocketHealth();
    });
  }

  /// Stop the socket health monitor.
  void stopHealthMonitor() {
    _socketHealthTimer?.cancel();
    _socketHealthTimer = null;
    _lastSegmentReceivedAt = null;
  }

  /// Check if transcription has stalled.
  void _checkSocketHealth() {
    try {
      if (_socket == null) return;

      // Skip stall detection for local STT: silence just means nobody is
      // talking — the on-device engine doesn't stall like a cloud WebSocket.
      if (_isLocalStt) return;

      // Only for custom STT mode
      final customSttConfig = SharedPreferencesUtil().customSttConfig;
      if (!customSttConfig.isEnabled) return;

      // Check if socket is disconnected
      if (_socket?.state != SocketServiceState.connected) {
        debugPrint(
            '[TranscriptionPipeline] Health monitor: socket disconnected');
        return;
      }

      // Check if segments have stopped arriving (>60s gap)
      if (_lastSegmentReceivedAt != null && segments.isNotEmpty) {
        final gap = DateTime.now().difference(_lastSegmentReceivedAt!);
        if (gap.inSeconds > 60) {
          _captureLog.log('health', 'health_check_stall_detected',
              severity: 'warning',
              details: {
                'gap_seconds': gap.inSeconds,
                'socket_connected':
                    _socket?.state == SocketServiceState.connected,
              });
          debugPrint(
              '[TranscriptionPipeline] Health monitor: no segments for ${gap.inSeconds}s');
          _handleTranscriptionStalled();
        }
      }
    } catch (e) {
      debugPrint('[TranscriptionPipeline] Health check error: $e');
    }
  }

  /// Called when transcription appears to have stalled.
  void _handleTranscriptionStalled() {
    if (_lastSegmentReceivedAt == null) return;

    _captureLog.log('health', 'transcription_stalled',
        severity: 'error',
        details: {
          'total_segments': segments.length,
          'reconnect_attempt': _sttReconnectAttempts,
        });

    // Clear timestamp to avoid repeated triggers
    _lastSegmentReceivedAt = null;

    _sttReconnectAttempts++;
    if (_sttReconnectAttempts > _maxSttReconnectAttempts) {
      debugPrint(
          '[TranscriptionPipeline] Max STT reconnect attempts reached ($_maxSttReconnectAttempts) - notifying user');
      _showStallNotification();
      onAutoFinalizeNeeded?.call();
      return;
    }

    debugPrint(
        '[TranscriptionPipeline] Transcription stalled - STT reconnect attempt $_sttReconnectAttempts/$_maxSttReconnectAttempts');

    // Delegate reconnection to CaptureProvider which knows recording state
    onTranscriptionStalled?.call();

    // Reset silence timer to give new socket time
    resetSilenceTimer();

    // Set timestamp so health monitor can detect if reconnected socket also stalls
    _lastSegmentReceivedAt = DateTime.now();
  }

  /// Show a notification when transcription stalled and reconnection failed.
  void _showStallNotification() {
    final lang = SharedPreferencesUtil().appLanguage;
    final title =
        lang == 'es' ? 'Transcripcion interrumpida' : 'Transcription Lost';
    final body = lang == 'es'
        ? 'No se han recibido segmentos de transcripcion en mas de 60 segundos.'
        : 'No transcription segments received for over 60 seconds.';

    NotificationService.instance.createNotification(
      title: title,
      body: body,
      notificationId: 3,
    );
  }

  // ---------------------------------------------------------------------------
  // Silence timer
  // ---------------------------------------------------------------------------

  /// Reset the silence timer - called when new segments arrive.
  void resetSilenceTimer({bool isSpeechProfileMode = false}) {
    if (isSpeechProfileMode) return;

    _silenceTimer?.cancel();

    final timeoutSeconds =
        SharedPreferencesUtil().conversationSilenceDuration;
    if (timeoutSeconds <= 0) return; // -1 = manual only

    _silenceTimer = Timer(Duration(seconds: timeoutSeconds), () {
      _onSilenceTimeout();
    });
  }

  void _onSilenceTimeout() {
    if (segments.isEmpty) {
      debugPrint(
          '[TranscriptionPipeline] Silence timeout with no segments');
      _captureLog.log('recording', 'silence_timeout_no_speech', details: {
        'timeout_seconds':
            SharedPreferencesUtil().conversationSilenceDuration,
      });
    }

    // Check if audio is still flowing (STT stall vs real silence).
    // BLE devices always send raw audio bytes (even during silence), so the
    // audio-flowing heuristic doesn't apply — treat timer expiry as real silence.
    if (!_isBleSource && _lastAudioBytesSentAt != null) {
      final audioGap = DateTime.now().difference(_lastAudioBytesSentAt!);
      if (audioGap.inSeconds < 10) {
        // Local STT: let silence timeout proceed normally.
        // Chunk processing every 5s doesn't mean speech is happening.
        if (_isLocalStt) {
          debugPrint(
              '[TranscriptionPipeline] Silence timeout with local STT — proceeding with auto-save');
          // Fall through to real silence callback below
        } else {
          debugPrint(
              '[TranscriptionPipeline] Silence timeout but audio still flowing (${audioGap.inSeconds}s ago) - STT stall');
          _captureLog.log('recording', 'silence_timeout_stt_stall', details: {
            'audio_gap_seconds': audioGap.inSeconds,
            'segments_count': segments.length,
          });
          _handleTranscriptionStalled();
          return;
        }
      }
    }

    // Real silence - notify CaptureProvider
    _captureLog.log('recording', 'silence_timeout_triggered', details: {
      'timeout_seconds':
          SharedPreferencesUtil().conversationSilenceDuration,
      'segments_count': segments.length,
    });
    debugPrint(
        '[TranscriptionPipeline] Silence timeout (${SharedPreferencesUtil().conversationSilenceDuration}s) - triggering callback');

    onSilenceTimeout?.call();
  }

  /// Cancel the silence timer.
  void cancelSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Connection state
  // ---------------------------------------------------------------------------

  /// Update connection state (called by ConnectivityService listener).
  void onConnectionStateChanged(bool connected) {
    _captureLog.log('recording', 'connection_state_changed', details: {
      'is_connected': connected,
    });
    _isConnected = connected;
    onNotifyListeners?.call();
  }

  // ---------------------------------------------------------------------------
  // Reconnection after resume
  // ---------------------------------------------------------------------------

  /// Reconnect socket after app resumes from background.
  Future<void> reconnectAfterResume({
    required BleAudioCodec audioCodec,
    bool force = true,
    String? source,
  }) async {
    _isReconnectingSocket = true;
    onNotifyListeners?.call();

    try {
      await _reconnectSocket(
          audioCodec: audioCodec, force: force, source: source);

      if (_socket?.state != SocketServiceState.connected) {
        debugPrint(
            '[TranscriptionPipeline] Immediate reconnect failed, starting keep-alive');
        _startKeepAlive();
      }
    } catch (e, stack) {
      DebugLogManager.logEvent('app_resumed_reconnect_error', {
        'error': e.toString(),
        'stack': stack.toString().substring(
            0, min(500, stack.toString().length)),
      });
      debugPrint(
          '[TranscriptionPipeline] Resume reconnect error: $e');
      _startKeepAlive();
    } finally {
      _isReconnectingSocket = false;
      startHealthMonitor();
      onNotifyListeners?.call();
    }
  }

  Future<void> _reconnectSocket({
    required BleAudioCodec audioCodec,
    bool force = true,
    String? source,
  }) async {
    DebugLogManager.logEvent('socket_reconnect_attempt', {
      'current_state': _socket != null ? _socket!.state.name : 'null',
    });

    debugPrint(
        '[TranscriptionPipeline] Attempting socket reconnect after resume');

    _isReconnecting = true;
    try {
      await _socket?.stop(reason: 'reconnect after resume');
      await Future.delayed(const Duration(milliseconds: 50));

      await initiateWebsocket(
        audioCodec: audioCodec,
        force: force,
        source: source,
      );

      DebugLogManager.logEvent('socket_reconnect_completed', {
        'new_state': _socket != null ? _socket!.state.name : 'null',
      });
    } finally {
      _isReconnecting = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Segment management
  // ---------------------------------------------------------------------------

  /// Clear all segments and reset state.
  void clearSegments() {
    segments.clear();
    _segmentController?.dispose();
    _segmentController = null;
    _segmentsVersion = 0;
    hasTranscripts = false;
    _lastSegmentReceivedAt = null;
    _sttReconnectAttempts = 0;
    _transcriptionServiceStatuses = [];
    _activeSttProvider = null;
    _audioTranscoder = null;
    // Cloud-only state (WAL, reconnect buffer, offset) is owned by the
    // orchestrator — reset/clear via its API.
    _cloudOrchestrator?.setWalEnabled(false);
    _cloudOrchestrator?.clearReconnectBuffer();
    _cloudOrchestrator?.resetTimestampOffset();
    vadSpeechActive.value = false;
  }

  // ---------------------------------------------------------------------------
  // Local STT engine (Parakeet / Moonshine / Canary)
  // ---------------------------------------------------------------------------

  /// Build a [LocalSttEngineService] from the user's preferences. Mirrors the
  /// config-reading logic used by [TranscriptSocketServiceFactory.createLocalStt]
  /// but returns the typed engine instead of a WebSocket-style adapter. Returns
  /// null when the model path isn't configured (caller should surface an error).
  LocalSttEngineService? _createLocalEngineFromConfig(SttProvider provider) {
    final prefs = SharedPreferencesUtil();
    final modelType = switch (provider) {
      SttProvider.localMoonshine => LocalSttModelType.moonshine,
      SttProvider.localCanary => LocalSttModelType.canary,
      _ => LocalSttModelType.parakeet,
    };
    final modelPath = switch (modelType) {
      LocalSttModelType.moonshine => prefs.localSttMoonshinePath,
      LocalSttModelType.canary => prefs.localSttCanaryPath,
      LocalSttModelType.parakeet => prefs.localSttModelPath,
    };
    if (modelPath.isEmpty) {
      debugPrint(
          '[TranscriptionPipeline] ${modelType.name} model path empty — local STT unavailable');
      return null;
    }

    String? speakerModelPath;
    Uint8List? userEmbeddingBytes;
    final speakerPath = prefs.speakerModelPath;
    final embeddingPath = prefs.localSpeakerEmbeddingPath;
    if (speakerPath.isNotEmpty && embeddingPath.isNotEmpty) {
      final f = File(embeddingPath);
      if (f.existsSync()) {
        final bytes = f.readAsBytesSync();
        if (bytes.length % 4 == 0 && bytes.isNotEmpty) {
          speakerModelPath = speakerPath;
          userEmbeddingBytes = bytes;
        }
      }
    }

    String? acousticProfileJson;
    final profilePath = prefs.acousticProfilePath;
    if (profilePath.isNotEmpty) {
      final f = File(profilePath);
      if (f.existsSync()) {
        try {
          acousticProfileJson = f.readAsStringSync();
        } catch (_) {}
      }
    }

    final double? maxSpeechDuration = switch (modelType) {
      LocalSttModelType.canary => prefs.localSttCanaryMaxSpeechDuration,
      LocalSttModelType.parakeet => 20.0,
      LocalSttModelType.moonshine => null,
    };

    return LocalSttEngineService(
      modelPath: modelPath,
      modelType: modelType,
      speakerModelPath: speakerModelPath,
      userEmbeddingBytes: userEmbeddingBytes,
      maxSpeechDuration: maxSpeechDuration,
      numThreads: DeviceMemoryService.cachedThreadCount,
      acousticProfileJson: acousticProfileJson,
    );
  }

  /// Hook the engine's typed callbacks into the pipeline's internal handlers.
  /// Done in [initiateWebsocket] before connect so no events are lost.
  void _wireLocalEngineCallbacks(LocalSttEngineService engine) {
    engine.onSegments = _onLocalSegments;
    engine.onVadStateChanged = onVadStateChanged;
    engine.onError = (err, _) => onError(err);
    // onStreamingHealthChanged and onChunkProcessed are wired by
    // [_wireChunkSocketCallbacks] once the chunk pipeline is initialized.
  }

  /// Local STT segments bypass [TranscriptSegmentSocketService]. They arrive
  /// as typed [TranscriptSegment] objects from the worker isolate and go
  /// directly into the same per-segment processing used by cloud STT.
  void _onLocalSegments(List<TranscriptSegment> segments) {
    if (segments.isEmpty) return;
    onSegmentReceived(segments);
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  /// Dispose all resources. Must be called when the pipeline is no longer needed.
  Future<void> dispose() async {
    // Cloud-side timers (keep-alive, token refresh) are cancelled by the
    // orchestrator's own dispose later in this method.
    _socketHealthTimer?.cancel();
    _socketHealthTimer = null;

    _silenceTimer?.cancel();
    _silenceTimer = null;

    _segmentNotifyPending = false;
    _segmentFrameInFlight = false;

    // Flush and dispose chunk writer + WAV backup (local STT)
    await _chunkWriter?.dispose();
    _chunkWriter = null;
    await _wavBackupService?.stop();
    _wavBackupService = null;
    _segmentController?.dispose();
    _segmentController = null;
    _audioTranscoder = null;

    await _vadService?.dispose();
    _vadService = null;
    vadStateNotifier.dispose();
    vadSpeechActive.dispose();

    await _cloudOrchestrator?.dispose();
    _cloudOrchestrator = null;
    await _localEngine?.disconnect();
    _localEngine = null;
    _transcriptServiceReady = false;
    _activeSttProvider = null;
  }
}
