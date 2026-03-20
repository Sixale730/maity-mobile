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
import 'package:omi/services/notifications/notification_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/sockets/transcription_service.dart';
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
  TranscriptSegmentSocketService? _socket;

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------
  Timer? _keepAliveTimer;
  DateTime? _keepAliveLastExecutedAt;
  int _keepAliveAttempts = 0;
  static const int _maxKeepAliveAttempts = 10;

  // ---------------------------------------------------------------------------
  // Health monitor
  // ---------------------------------------------------------------------------
  Timer? _socketHealthTimer;
  DateTime? _lastSegmentReceivedAt;
  int _sttReconnectAttempts = 0;
  static const int _maxSttReconnectAttempts = 3;
  DateTime? _lastAudioBytesSentAt;

  // ---------------------------------------------------------------------------
  // Token refresh
  // ---------------------------------------------------------------------------
  Timer? _tokenRefreshTimer;

  // ---------------------------------------------------------------------------
  // Silence timer
  // ---------------------------------------------------------------------------
  Timer? _silenceTimer;

  // ---------------------------------------------------------------------------
  // Segment notification throttling
  // ---------------------------------------------------------------------------
  Timer? _segmentNotifyTimer;
  DateTime? _lastSegmentNotifyTime;
  static const Duration _segmentNotifyMinInterval =
      Duration(milliseconds: 800);

  // ---------------------------------------------------------------------------
  // Segments state
  // ---------------------------------------------------------------------------
  List<TranscriptSegment> segments = [];
  int _segmentsVersion = 0;
  int get segmentsVersion => _segmentsVersion;
  bool hasTranscripts = false;

  // ---------------------------------------------------------------------------
  // Connection state
  // ---------------------------------------------------------------------------
  bool _isConnected = true;
  bool get isConnected => _isConnected;

  // ---------------------------------------------------------------------------
  // Socket state
  // ---------------------------------------------------------------------------
  bool _transcriptServiceReady = false;
  bool get transcriptServiceReady => _transcriptServiceReady && _isConnected;

  /// Access the underlying socket for sending audio bytes.
  TranscriptSegmentSocketService? get socket => _socket;

  // ---------------------------------------------------------------------------
  // WAL (Write-Ahead Log) support
  // ---------------------------------------------------------------------------
  bool _walEnabled = false;

  /// Enable or disable WAL audio buffering.
  void setWalEnabled(bool enabled) {
    _walEnabled = enabled;
  }

  // ---------------------------------------------------------------------------
  // Timestamp offset for Deepgram reconnections
  // ---------------------------------------------------------------------------
  /// Cumulative time offset for Deepgram timestamp correction across reconnections.
  /// Each new Deepgram session starts at t=0; we offset by the elapsed recording time.
  Duration _cumulativeOffset = Duration.zero;

  /// Timestamp of the recording start (set when first socket connects).
  DateTime? _recordingStartTime;

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

    // Update timestamp offset on reconnection (not first connection)
    if (_recordingStartTime != null) {
      _updateTimestampOffset();
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

    if (effectiveConfig != null &&
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

    // Connect to the transcript socket
    try {
      _socket = await ServiceManager.instance().socket.conversation(
            codec: codec,
            sampleRate: sampleRate,
            language: language,
            force: force,
            source: source,
            customSttConfig: effectiveConfig,
          );
    } catch (e) {
      _captureLog.log('socket', 'websocket_connection_failed',
          severity: 'error',
          details: {
            'error': e.toString(),
            'codec': codec.name,
            'custom_stt': effectiveConfig != null,
          });
      debugPrint('[TranscriptionPipeline] WebSocket connection failed: $e');
      _startKeepAlive();
      return;
    }
    if (_socket == null) {
      _captureLog.log('socket', 'websocket_creation_failed',
          severity: 'error',
          details: {
            'codec': codec.name,
            'custom_stt': effectiveConfig != null,
          });
      _startKeepAlive();
      debugPrint("Can not create new conversation socket");
      return;
    }
    _socket?.subscribe(this, this);
    _transcriptServiceReady = true;

    // Track recording start time for timestamp offset calculation
    _recordingStartTime ??= DateTime.now();

    // Proactive token refresh: reconnect before JWT expires (~1hr)
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = Timer(const Duration(minutes: 50), () {
      _captureLog.log('socket', 'token_refresh_reconnect', details: {});
      onTranscriptionStalled?.call();
    });

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
    _tokenRefreshTimer?.cancel();
    _captureLog.log('socket', 'socket_stopping',
        details: {'reason': reason});
    await _socket?.stop(reason: reason);
    _socket = null;
    _transcriptServiceReady = false;
  }

  /// Updates the cumulative timestamp offset based on elapsed recording time.
  /// Called before reconnecting the socket so new Deepgram segments (which
  /// restart at t=0) are shifted to the correct position in the timeline.
  void _updateTimestampOffset() {
    if (_recordingStartTime != null) {
      _cumulativeOffset = DateTime.now().difference(_recordingStartTime!);
      debugPrint(
          '[TranscriptionPipeline] Updated timestamp offset: ${_cumulativeOffset.inSeconds}s');
    }
  }

  /// Resets the timestamp offset state. Called when recording fully stops.
  void resetTimestampOffset() {
    _cumulativeOffset = Duration.zero;
    _recordingStartTime = null;
  }

  /// Send raw bytes to the socket (used by AudioTransportService).
  /// WAL captures all audio frames; only marks as synced what the socket received.
  void sendToSocket(dynamic data) {
    // Always capture to WAL (Write-Ahead Log) for recovery on reconnect
    if (_walEnabled && data is List<int>) {
      try {
        ServiceManager.instance().wal.getSyncs().phone.onByteStream(data);
      } catch (e) {
        debugPrint('[TranscriptionPipeline] WAL onByteStream error: $e');
      }
    }

    if (_socket?.state == SocketServiceState.connected) {
      _socket?.send(data);
      // Mark as synced in WAL only after successful send
      if (_walEnabled && data is List<int>) {
        try {
          ServiceManager.instance().wal.getSyncs().phone.onBytesSync(data);
        } catch (e) {
          debugPrint('[TranscriptionPipeline] WAL onBytesSync error: $e');
        }
      }
    }
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
      _transcriptionServiceStatuses = [];
      _transcriptServiceReady = false;
      onNotifyListeners?.call();
      // Don't start keep-alive for terminal errors
      return;
    }

    // Temporal errors - attempt immediate reconnect, fall back to keep-alive
    _captureLog.log('socket', 'socket_error_temporal',
        severity: 'warning', details: {'error': errorStr});
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
    _keepAliveAttempts = 0;
    onNotifyListeners?.call();
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

    _transcriptServiceReady = false;

    // Cancel keep-alive and health monitor — the socket won't recover
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
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

    // Apply cumulative offset for reconnection timestamp correction
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

    if (segments.isEmpty) {
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

    assert(() {
      debugPrint(
          '[TranscriptionPipeline] After update: ${segments.length} total segments');
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

  /// Throttled notification for segment updates.
  /// Ensures at most ~1.25 rebuilds per second during rapid speech.
  void _notifySegmentUpdate() {
    final now = DateTime.now();
    if (_lastSegmentNotifyTime != null &&
        now.difference(_lastSegmentNotifyTime!) < _segmentNotifyMinInterval) {
      // Within throttle window — schedule a deferred notification
      _segmentNotifyTimer?.cancel();
      _segmentNotifyTimer = Timer(
        _segmentNotifyMinInterval - now.difference(_lastSegmentNotifyTime!),
        () {
          _lastSegmentNotifyTime = DateTime.now();
          _segmentNotifyTimer = null;
          onNotifyListeners?.call();
        },
      );
      return;
    }
    // Outside throttle window — notify immediately
    _lastSegmentNotifyTime = now;
    _segmentNotifyTimer?.cancel();
    _segmentNotifyTimer = null;
    onNotifyListeners?.call();
  }

  void setHasTranscripts(bool value) {
    hasTranscripts = value;
  }

  // ---------------------------------------------------------------------------
  // Keep-alive
  // ---------------------------------------------------------------------------

  /// Start keep-alive periodic timer for reconnecting a dead socket.
  void _startKeepAlive() {
    _captureLog.log('socket', 'keepalive_started');
    _keepAliveTimer?.cancel();
    _keepAliveAttempts = 0;

    _keepAliveTimer =
        Timer.periodic(const Duration(seconds: 15), (t) async {
      _keepAliveAttempts++;

      DebugLogManager.logEvent('keep_alive_tick', {
        'attempt': _keepAliveAttempts,
        'max_attempts': _maxKeepAliveAttempts,
        'socket_state': _socket != null ? _socket!.state.name : 'null',
      });

      debugPrint(
          "[TranscriptionPipeline] keep alive - attempt $_keepAliveAttempts/$_maxKeepAliveAttempts");

      // Check if max attempts reached
      if (_keepAliveAttempts >= _maxKeepAliveAttempts) {
        DebugLogManager.logEvent('keep_alive_max_reached', {
          'attempts': _keepAliveAttempts,
        });
        debugPrint(
            "[TranscriptionPipeline] keep alive - max attempts reached, stopping");
        t.cancel();
        _keepAliveTimer = null;
        // Auto-finalize conversation with existing segments
        await onAutoFinalizeNeeded?.call();
        return;
      }

      // H5 bug fix: Correct rate limit check
      // The original code had inverted logic that was always true immediately.
      if (_keepAliveLastExecutedAt != null) {
        final elapsed =
            DateTime.now().difference(_keepAliveLastExecutedAt!);
        if (elapsed.inSeconds < 15) {
          debugPrint(
              "[TranscriptionPipeline] keep alive - rate limited (${elapsed.inSeconds}s since last)");
          return;
        }
      }

      _keepAliveLastExecutedAt = DateTime.now();

      // If socket is already connected, stop keep-alive
      if (_socket?.state == SocketServiceState.connected) {
        debugPrint(
            "[TranscriptionPipeline] keep alive - socket connected, stopping");
        t.cancel();
        _keepAliveTimer = null;
        _keepAliveAttempts = 0;
        return;
      }

      // Attempt reconnection - let CaptureProvider decide which codec/source
      // by calling initiateWebsocket through the stall handler
      await onTranscriptionStalled?.call();
    });
  }

  /// Start keep-alive timer (public entry point for delegate).
  void startKeepAlive() {
    _startKeepAlive();
  }

  /// Stop the keep-alive timer.
  void stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _keepAliveAttempts = 0;
    _keepAliveLastExecutedAt = null;
  }

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
  /// Only active for custom STT mode.
  void resetSilenceTimer({bool isSpeechProfileMode = false}) {
    if (isSpeechProfileMode) return;

    final customSttConfig = SharedPreferencesUtil().customSttConfig;
    if (!customSttConfig.isEnabled) return;

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

    // Check if audio is still flowing (STT stall vs real silence)
    if (_lastAudioBytesSentAt != null) {
      final audioGap = DateTime.now().difference(_lastAudioBytesSentAt!);
      if (audioGap.inSeconds < 10) {
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
    _lastSegmentReceivedAt = null;
    _sttReconnectAttempts = 0;
    _transcriptionServiceStatuses = [];
    _walEnabled = false;
    resetTimestampOffset();
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  /// Dispose all resources. Must be called when the pipeline is no longer needed.
  Future<void> dispose() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = null;

    _socketHealthTimer?.cancel();
    _socketHealthTimer = null;

    _silenceTimer?.cancel();
    _silenceTimer = null;

    _segmentNotifyTimer?.cancel();
    _segmentNotifyTimer = null;

    await _vadService?.dispose();
    _vadService = null;
    vadStateNotifier.dispose();

    await _socket?.stop(reason: 'pipeline disposed');
    _socket = null;
    _transcriptServiceReady = false;
    resetTimestampOffset();
  }
}
