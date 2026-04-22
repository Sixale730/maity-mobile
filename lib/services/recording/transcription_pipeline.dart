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
import 'package:omi/services/stt/local/local_stt_model_type.dart';
import 'package:omi/services/stt/local/model_download_service.dart';
import 'package:omi/services/stt/cloud/cloud_stt_orchestrator.dart';
import 'package:omi/services/stt/local/local_stt_engine_service.dart';
import 'package:omi/services/stt/local/local_stt_orchestrator.dart';
import 'package:omi/services/recording/telemetry_collector.dart';
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

  /// Local STT transport (Parakeet / Moonshine / Canary). Null when cloud
  /// STT is active. Owns the worker isolate, chunk pipeline, streaming
  /// fast-path toggle, and WAV backup — symmetric with [_cloudOrchestrator].
  LocalSttOrchestrator? _localOrchestrator;

  /// Expose local orchestrator for segment snapshot collection.
  /// Read-only — caller must NOT dispose.
  LocalSttOrchestrator? get localOrchestrator => _localOrchestrator;

  /// Invoked on recording stop when the active engine was injected (not
  /// built by the pipeline). The owner (LocalSttProvider) keeps the engine
  /// alive for the next acquire rather than tearing it down.
  void Function(LocalSttEngineService engine)? onLocalEngineReleased;

  /// Optional supplier that, when set, is queried at the start of each
  /// [initiateWebsocket] cloud/local branch to reuse a pre-warmed engine.
  /// The typical wiring is CaptureProvider → LocalSttProvider.acquireEngine.
  /// Returning null causes the pipeline to cold-build an engine as before.
  LocalSttEngineService? Function()? warmEngineProvider;

  // Keep-alive, token refresh, and health monitor timers/counters: owned
  // by [CloudSttOrchestrator]. Pipeline reads them through the orchestrator
  // so its own _checkSocketHealth / _handleTranscriptionStalled can still
  // reason about stall state without duplicating fields.

  // ---------------------------------------------------------------------------
  // External audio-flow tracking
  // ---------------------------------------------------------------------------
  DateTime? _externalLastAudioAt;

  /// Set an external audio-flow timestamp. Used by SessionLifecycleManager
  /// to track the last time audio was received for silence detection in
  /// local STT sessions.
  void setExternalAudioFlowTimestamp(DateTime? timestamp) {
    _externalLastAudioAt = timestamp;
  }

  /// Read the external audio-flow timestamp.
  DateTime? get externalLastAudioAt => _externalLastAudioAt;

  // Note: _isBleSource guard removed — audio-flow timestamp tracking now
  // covers both BLE and phone mic uniformly via _externalLastAudioAt.

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

  /// VAD activity indicator — replaces preview text.
  /// True when the worker's VAD detects active speech.
  final ValueNotifier<bool> vadSpeechActive = ValueNotifier(false);

  /// Segments from the bounded UISegmentController (local STT) or the
  /// unbounded list (cloud STT) for display.
  List<TranscriptSegment> get displaySegments =>
      _localOrchestrator?.displaySegments ?? segments;

  /// Whether the chunk pipeline has audio data that hasn't been decoded yet.
  /// Used to prevent premature cancel when back is pressed before first segment.
  bool get hasUnprocessedAudio =>
      _localOrchestrator?.hasUnprocessedAudio ?? false;

  /// Whether archived pages are available for scroll-up pagination.
  bool get hasArchivedPages =>
      _localOrchestrator?.hasArchivedPages ?? false;

  /// Load an archived page of segments (for scroll-up pagination).
  Future<List<TranscriptSegment>> loadArchivedPage(int pageIndex) =>
      _localOrchestrator?.loadArchivedPage(pageIndex) ?? Future.value([]);

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
  // Health signals exposed for RecordingHealthMonitor consumers.
  //
  // Pipeline-agnostic getters so monitors don't need to know whether the
  // session is cloud or local — callers pass these as lambdas to the
  // appropriate monitor impl.
  // ---------------------------------------------------------------------------

  /// Last time audio bytes were sent over the transport. For cloud STT this
  /// comes from the orchestrator's socket layer; for local STT it comes from
  /// the external timestamp set by SessionLifecycleManager.
  DateTime? get lastAudioBytesSentAt =>
      _cloudOrchestrator?.lastAudioBytesSentAt ?? _externalLastAudioAt;

  /// Last time a transcript segment was received. Null until the first
  /// segment arrives. Local STT also updates this when worker emits segments.
  DateTime? get lastSegmentReceivedAt =>
      _cloudOrchestrator?.lastSegmentReceivedAt;

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
    LocalSttEngineService? warmEngine,
  }) async {
    Logger.debug('initiateWebsocket in TranscriptionPipeline');

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

    // Auto-fallback to local STT when offline and any model is ready.
    // Covers both: no custom config (effectiveConfig == null) AND cloud
    // config active (e.g. Deepgram) — avoids 150s of keep-alive retries
    // hammering a dead cloud socket while a local model sits idle.
    final isOffline = !ConnectivityService().isConnected;
    final shouldFallbackToLocal = isOffline &&
        SharedPreferencesUtil().localSttAutoFallback &&
        ModelDownloadService.instance.isAnyModelReady;

    if (shouldFallbackToLocal &&
        (effectiveConfig == null ||
            !_isLocalSttProvider(effectiveConfig.provider))) {
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

    // Local STT branch: delegate to LocalSttOrchestrator which owns the
    // worker isolate, chunk pipeline, streaming fast-path, and WAV backup.
    if (effectiveConfig != null &&
        _isLocalSttProvider(effectiveConfig.provider)) {
      final orch = LocalSttOrchestrator(
        provider: effectiveConfig.provider,
        codec: codec,
        sessionId: chunkSessionId ?? 'unknown',
        streamingEnabled: SharedPreferencesUtil().useStreamingPipeline,
        captureLog: _captureLog,
        warmEngine: warmEngine ?? warmEngineProvider?.call(),
        onSegments: (segs) => _processNewSegmentReceived(segs),
        onVadStateChanged: onVadStateChanged,
        onError: (err) => onError(err),
        onEngineReleased: onLocalEngineReleased,
        onNotifyListeners: () => onNotifyListeners?.call(),
      );
      final ok = await orch.connect();
      if (!ok) return;
      await orch.initChunkPipeline();
      _localOrchestrator = orch;
      _transcriptServiceReady = true;
      _activeSttProvider = effectiveConfig.provider;
      TelemetryCollector.instance.setSttProvider(_activeSttProvider?.name);
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
          final fallbackOrch = LocalSttOrchestrator(
            provider: fallbackProvider,
            codec: codec,
            sessionId: chunkSessionId ?? 'unknown',
            streamingEnabled: SharedPreferencesUtil().useStreamingPipeline,
            captureLog: _captureLog,
            onSegments: (segs) => _processNewSegmentReceived(segs),
            onVadStateChanged: onVadStateChanged,
            onError: (err) => onError(err),
            onEngineReleased: onLocalEngineReleased,
            onNotifyListeners: () => onNotifyListeners?.call(),
          );
          if (await fallbackOrch.connect()) {
            await fallbackOrch.initChunkPipeline();
            _localOrchestrator = fallbackOrch;
            _transcriptServiceReady = true;
            _activeSttProvider = fallbackProvider;
            TelemetryCollector.instance
                .setSttProvider(_activeSttProvider?.name);
            return;
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

    await _localOrchestrator?.dispose();
    _localOrchestrator = null;

    _transcriptServiceReady = false;
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
    // Local STT: delegate to the orchestrator (dual-write + streaming).
    if (_isLocalStt && _localOrchestrator != null && data is List<int>) {
      _localOrchestrator!.sendAudio(data);
      return;
    }

    // Cloud STT path: the orchestrator handles WAL capture, socket send,
    // and reconnect buffering.
    _cloudOrchestrator?.sendAudio(data);
  }

  // ---------------------------------------------------------------------------
  // Chunk pipeline setup (local STT only)
  // ---------------------------------------------------------------------------

  /// Session ID for the current chunk pipeline. Set by CaptureProvider.
  String? chunkSessionId;

  /// Flush the chunk writer (for app lifecycle pause).
  Future<void> flushChunkWriter({bool synchronous = false}) async {
    await _localOrchestrator?.flushChunkWriter(synchronous: synchronous);
  }

  /// Update the last audio bytes sent timestamp (for STT stall detection).
  void updateLastAudioBytesSentAt() {
    _cloudOrchestrator?.updateLastAudioBytesSentAt();
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

    final segCtrl = _localOrchestrator?.segmentController;
    if (segments.isEmpty && (segCtrl?.activeSegments.isEmpty ?? true)) {
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
    if (segCtrl != null) {
      segCtrl.addSegments(newSegments);
      _segmentsVersion = segCtrl.version;
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

    // Update health monitor timestamp (no-op when local STT is active).
    _cloudOrchestrator?.markSegmentReceived();

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
  /// No-op when local STT is active — the on-device engine doesn't stall
  /// like a cloud WebSocket, so we don't need to watch it.
  void startHealthMonitor() {
    _cloudOrchestrator?.startHealthMonitor(_checkSocketHealth);
  }

  /// Stop the socket health monitor.
  void stopHealthMonitor() {
    _cloudOrchestrator?.stopHealthMonitor();
  }

  /// Check if transcription has stalled. Fires every 10 s from the
  /// orchestrator's timer.
  void _checkSocketHealth() {
    try {
      if (_socket == null) return;
      if (_isLocalStt) return;

      final customSttConfig = SharedPreferencesUtil().customSttConfig;
      if (!customSttConfig.isEnabled) return;

      if (_socket?.state != SocketServiceState.connected) {
        debugPrint(
            '[TranscriptionPipeline] Health monitor: socket disconnected');
        return;
      }

      final lastAt = _cloudOrchestrator?.lastSegmentReceivedAt;
      if (lastAt != null && segments.isNotEmpty) {
        final gap = DateTime.now().difference(lastAt);
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
    final orchestrator = _cloudOrchestrator;
    if (orchestrator == null) return;
    if (orchestrator.lastSegmentReceivedAt == null) return;

    final attemptBefore = orchestrator.sttReconnectAttempts;
    _captureLog.log('health', 'transcription_stalled',
        severity: 'error',
        details: {
          'total_segments': segments.length,
          'reconnect_attempt': attemptBefore,
        });

    // Clear timestamp to avoid repeated triggers while reconnect is in flight.
    orchestrator.clearLastSegmentReceivedAt();

    final attempt = orchestrator.incrementSttReconnectAttempts();
    if (attempt > orchestrator.maxSttReconnectAttempts) {
      debugPrint(
          '[TranscriptionPipeline] Max STT reconnect attempts reached (${orchestrator.maxSttReconnectAttempts}) - notifying user');
      _showStallNotification();
      onAutoFinalizeNeeded?.call();
      return;
    }

    debugPrint(
        '[TranscriptionPipeline] Transcription stalled - STT reconnect attempt $attempt/${orchestrator.maxSttReconnectAttempts}');

    // Delegate reconnection to CaptureProvider which knows recording state
    onTranscriptionStalled?.call();

    // Reset silence timer to give new socket time
    resetSilenceTimer();

    // Restamp so the monitor can detect if the reconnected socket also stalls.
    orchestrator.touchLastSegmentReceivedAt();
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
    // Use cloud orchestrator timestamp if available, fall back to external
    // timestamp (set by SessionLifecycleManager for local STT sessions).
    final lastAudioAt = _cloudOrchestrator?.lastAudioBytesSentAt ?? _externalLastAudioAt;
    if (lastAudioAt != null) {
      final audioGap = DateTime.now().difference(lastAudioAt);
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
    _segmentsVersion = 0;
    hasTranscripts = false;
    _transcriptionServiceStatuses = [];
    _activeSttProvider = null;
    // Cloud-only state lives in the orchestrator — reset via its API.
    _cloudOrchestrator?.setWalEnabled(false);
    _cloudOrchestrator?.clearReconnectBuffer();
    _cloudOrchestrator?.resetTimestampOffset();
    _cloudOrchestrator?.resetHealth();
    vadSpeechActive.value = false;
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  /// Dispose all resources. Must be called when the pipeline is no longer needed.
  Future<void> dispose() async {
    _silenceTimer?.cancel();
    _silenceTimer = null;

    _segmentNotifyPending = false;
    _segmentFrameInFlight = false;

    await _vadService?.dispose();
    _vadService = null;
    vadStateNotifier.dispose();
    vadSpeechActive.dispose();

    await _cloudOrchestrator?.dispose();
    _cloudOrchestrator = null;
    await _localOrchestrator?.dispose();
    _localOrchestrator = null;
    _transcriptServiceReady = false;
    _activeSttProvider = null;
  }
}
