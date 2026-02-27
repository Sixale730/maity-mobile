import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/message.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/person.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/providers/people_provider.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/sockets/transcription_service.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/services/local_conversations_service.dart';
import 'package:omi/services/conversation_processor.dart';
import 'package:omi/services/transcript_recovery_service.dart';
import 'package:omi/services/incremental_save_service.dart';
import 'package:omi/services/omi_supabase_service.dart';
import 'package:omi/services/notifications/notification_service.dart';
import 'package:uuid/uuid.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/services/voice_profile_service.dart';
import 'package:omi/services/vad/vad_service.dart';
import 'package:omi/services/vad/vad_state.dart';
import 'package:omi/services/vad/vad_metrics.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/image/image_utils.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:permission_handler/permission_handler.dart';

class CaptureProvider extends ChangeNotifier
    with MessageNotifierMixin, WidgetsBindingObserver
    implements ITransctiptSegmentSocketServiceListener {
  /// Flag to indicate phone mic recording is active (used by DeviceProvider to skip BLE reconnection)
  static bool isRecordingWithPhoneMic = false;
  ConversationProvider? conversationProvider;
  MessageProvider? messageProvider;
  PeopleProvider? peopleProvider;
  UsageProvider? usageProvider;

  TranscriptSegmentSocketService? _socket;
  Timer? _keepAliveTimer;
  DateTime? _keepAliveLastExecutedAt;

  // Method channel for system audio permissions
  static late MethodChannel _screenCaptureChannel;
  static late MethodChannel _controlBarChannel;

  IWalService get _wal => ServiceManager.instance().wal;

  bool _isWalSupported = false;

  bool get isWalSupported => _isWalSupported;

  StreamSubscription<bool>? _connectionStateListener;
  bool _isConnected = ConnectivityService().isConnected;

  get isConnected => _isConnected;

  String? microphoneName;
  double microphoneLevel = 0.0;
  double systemAudioLevel = 0.0;

  bool _isAutoReconnecting = false;
  bool get isAutoReconnecting => _isAutoReconnecting;

  bool get outOfCredits => usageProvider?.isOutOfCredits ?? false;

  Timer? _reconnectTimer;
  int _reconnectCountdown = 5;
  int get reconnectCountdown => _reconnectCountdown;

  // Silence timer for auto-save with custom STT
  Timer? _silenceTimer;

  // Recovery service for persisting segments in case of crash
  Timer? _recoveryTimer;
  int _unsavedSegmentCount = 0;
  String? _currentSessionId;

  // Throttled notifyListeners for segment updates (max ~3 rebuilds/sec)
  Timer? _segmentNotifyTimer;
  DateTime? _lastSegmentNotifyTime;
  static const Duration _segmentNotifyMinInterval = Duration(milliseconds: 300);

  // Incremental save service for saving segments to Supabase during recording
  final IncrementalSaveService _incrementalSave = IncrementalSaveService();

  /// Maximum segments kept in memory. Older saved segments are trimmed.
  static const int _maxSegmentsInMemory = 200;

  /// Total segments produced in this session (survives trimming, for accurate logs)
  int _totalSegmentCount = 0;

  // Health monitor for detecting stalled transcription
  Timer? _socketHealthTimer;
  DateTime? _lastSegmentReceivedAt;

  // STT reconnection tracking
  int _sttReconnectAttempts = 0;
  static const int _maxSttReconnectAttempts = 3;

  // Tracks when audio bytes were last sent to STT (to distinguish STT stall from real silence)
  DateTime? _lastAudioBytesSentAt;

  Timer? _recordingTimer;
  int _recordingDuration = 0; // in seconds
  DateTime? _recordingStartTime; // Track when recording started for local conversations
  bool _conversationFinalized = false; // Prevents duplicate saves when stopping recording
  bool _finalizeInProgress = false; // Prevents _resetStateVariables() from wiping state during in-flight finalize
  bool _isSpeechProfileMode = false; // Blocks conversation save during speech profile training
  int _audioBytesSent = 0; // Diagnostic counter for audio bytes sent to STT

  int _getRecordingDuration() => _recordingDuration;

  List<MessageEvent> _transcriptionServiceStatuses = [];
  List<MessageEvent> get transcriptionServiceStatuses => _transcriptionServiceStatuses;

  List<int> _systemAudioBuffer = [];
  bool _systemAudioCaching = true;

  // BLE streaming metrics
  int _blesBytesReceived = 0;
  int _wsSocketBytesSent = 0;
  double _bleReceiveRateKbps = 0.0;
  double _wsSendRateKbps = 0.0;
  DateTime? _metricsLastCalculated;
  Timer? _metricsTimer;
  int _metricsLogCounter = 0;

  double get bleReceiveRateKbps => _bleReceiveRateKbps;
  double get wsSendRateKbps => _wsSendRateKbps;

  // Audio buffer for speaker verification (stores audio during recording)
  WavBytesUtil? _audioBuffer;

  // Voice Activity Detection (VAD) service
  VadService? _vadService;
  VadMetrics? get vadMetrics => _vadService?.getMetricsSnapshot();
  bool get isVadActive => _vadService != null && _vadService!.isInitialized;

  // ValueNotifier for real-time VAD state updates (used by Developer Settings)
  final ValueNotifier<VadState?> vadStateNotifier = ValueNotifier(null);

  CaptureLogService get _captureLog => CaptureLogService.instance;

  String _socketStateName() => _socket?.state.name ?? 'null';

  // Keep-alive attempt tracking to prevent infinite reconnection loops
  int _keepAliveAttempts = 0;
  static const int _maxKeepAliveAttempts = 10;

  // Background finalize timer: auto-finalizes if socket stays dead while app is in background
  Timer? _backgroundFinalizeTimer;

  // Flag to suppress keep-alive during intentional reconnection after resume
  bool _isReconnectingAfterResume = false;

  // Flag to indicate socket is reconnecting after resume (for UI feedback)
  bool _isReconnectingSocket = false;
  bool get isReconnectingSocket => _isReconnectingSocket;

  CaptureProvider() {
    _connectionStateListener = ConnectivityService().onConnectionChange.listen((bool isConnected) {
      onConnectionStateChanged(isConnected);
    });

    // Register lifecycle observer on ALL platforms (mobile + desktop)
    // This is critical for handling app paused/resumed states
    WidgetsBinding.instance.addObserver(this);

    if (PlatformService.isDesktop) {
      _screenCaptureChannel = const MethodChannel('screenCapturePlatform');
      _controlBarChannel = const MethodChannel('com.omi/floating_control_bar');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _controlBarChannel.setMethodCallHandler(_handleFloatingControlBarMethodCall);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    DebugLogManager.logEvent('app_lifecycle_changed', {
      'state': state.name,
      'recording_state': recordingState.name,
      'has_device': _recordingDevice != null,
      'socket_state': _socket != null ? _socket!.state.name : 'null',
      'is_paused': _isPaused,
      'has_draft': _incrementalSave.draftId != null,
      'segment_count': segments.length,
      'platform': PlatformService.isDesktop ? 'desktop' : 'mobile',
    });

    switch (state) {
      case AppLifecycleState.paused:
        _handleAppPaused();
        break;
      case AppLifecycleState.resumed:
        _handleAppResumed();
        break;
      case AppLifecycleState.detached:
        _handleAppDetached();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Just logging, no action needed
        debugPrint('[CaptureProvider] Lifecycle: $state');
        break;
    }
  }

  /// Handle app going to background (screen locked, app minimized)
  void _handleAppPaused() {
    DebugLogManager.logEvent('app_paused_handling', {
      'action': 'stopping_background_services',
      'socket_state': _socket != null ? _socket!.state.name : 'null',
      'recording_state': recordingState.name,
      'segment_count': segments.length,
    });

    debugPrint('[CaptureProvider] App paused - stopping health monitor and keep-alive');

    // Stop health monitor to avoid reconnections while in background
    _stopSocketHealthMonitor();

    // Cancel keep-alive timer to prevent reconnection attempts in background
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    // Start background finalize timer: if socket stays dead for 3 min, auto-finalize
    final isRecording = recordingState == RecordingState.record ||
        recordingState == RecordingState.deviceRecord ||
        recordingState == RecordingState.systemAudioRecord;
    if (isRecording && segments.isNotEmpty) {
      _startBackgroundFinalizeTimer();
    }

    // Save recovery data immediately to prevent data loss (synchronous: app may be killed)
    if (segments.isNotEmpty && !_isSpeechProfileMode) {
      debugPrint('[CaptureProvider] Saving recovery data before pause');
      _saveRecoveryData(synchronous: true);
    }
  }

  /// Handle app being terminated
  void _handleAppDetached() {
    DebugLogManager.logEvent('app_detached_handling', {
      'action': 'cleanup',
      'recording_state': recordingState.name,
      'segment_count': segments.length,
    });

    debugPrint('[CaptureProvider] App detached - performing cleanup');

    // Save recovery data before stopping socket — OS may kill the app without
    // going through paused state, so this is our last chance to persist segments
    if (segments.isNotEmpty && !_isSpeechProfileMode) {
      debugPrint('[CaptureProvider] Saving recovery data before detach');
      _saveRecoveryData(synchronous: true);
    }

    // Stop socket cleanly
    _socket?.stop(reason: 'app detached');
  }

  /// Starts a timer that auto-finalizes the conversation if the socket
  /// remains disconnected while the app is in background for 3 minutes.
  void _startBackgroundFinalizeTimer() {
    _backgroundFinalizeTimer?.cancel();
    _backgroundFinalizeTimer = Timer(const Duration(minutes: 3), () {
      // If socket is still disconnected after 3 min in background, finalize
      if (_socket?.state != SocketServiceState.connected && segments.isNotEmpty && !_conversationFinalized) {
        _captureLog.log('recording', 'background_auto_finalize', severity: 'warning', details: {
          'segments_count': segments.length,
          'socket_state': _socket?.state.name ?? 'null',
          'minutes_in_background': 3,
        });
        debugPrint('[CaptureProvider] Background timer: socket dead for 3 min, auto-finalizing');
        _autoFinalizeOnConnectionLost();
      }
    });
  }

  /// Handle app returning from background
  void _handleAppResumed() async {
    // Cancel background finalize timer since user is back
    _backgroundFinalizeTimer?.cancel();
    _backgroundFinalizeTimer = null;

    DebugLogManager.logEvent('app_resumed_handling_start', {
      'recording_state': recordingState.name,
      'socket_state': _socket != null ? _socket!.state.name : 'null',
      'is_mobile': !PlatformService.isDesktop,
      'has_device': _recordingDevice != null,
      'segment_count': segments.length,
    });

    debugPrint('[CaptureProvider] App resumed - checking state');

    // Desktop-specific auto-resume logic for system audio
    if (PlatformService.isDesktop && _shouldAutoResumeAfterWake) {
      try {
        final nativeRecording = await _screenCaptureChannel.invokeMethod('isRecording') ?? false;

        if (!nativeRecording && recordingState != RecordingState.stop) {
          updateRecordingState(RecordingState.stop);
          await _socket?.stop(reason: 'native recording stopped during sleep');
        }

        if (!nativeRecording && recordingState == RecordingState.stop) {
          await Future.delayed(const Duration(seconds: 2));
          await streamSystemAudioRecording();
        }
      } catch (e) {
        debugPrint('[CaptureProvider] Desktop resume error: $e');
      }
      return;
    }

    // Mobile: handle socket reconnection if we were recording
    final isRecording = recordingState == RecordingState.record ||
        recordingState == RecordingState.deviceRecord ||
        recordingState == RecordingState.systemAudioRecord;

    if (isRecording) {
      // Cancel any running keep-alive before reconnecting to avoid cascading reconnections
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;

      // Check if socket needs reconnection
      if (_socket != null && _socket!.state != SocketServiceState.connected) {
        _isReconnectingSocket = true;
        notifyListeners(); // UI shows "reconnecting" state immediately

        // Fire-and-forget: does NOT block the event loop
        _reconnectSocketAfterResumeAsync();
      } else {
        // Socket still connected, just restart health monitor
        _startSocketHealthMonitor();
      }
    }
    // REMOVED: refreshInProgressConversations() - already called inside _initiateWebsocket
    // REMOVED: Future.delayed for non-recording - HomePage.ConversationProvider handles it
  }

  /// Reconnect socket after app resumes from background
  Future<void> _reconnectSocketAfterResume() async {
    DebugLogManager.logEvent('socket_reconnect_attempt', {
      'current_state': _socket != null ? _socket!.state.name : 'null',
      'recording_state': recordingState.name,
    });

    debugPrint('[CaptureProvider] Attempting socket reconnect after resume');

    // Set flag to prevent onClosed() from triggering keep-alive during this stop
    _isReconnectingAfterResume = true;
    try {
      // Stop current socket cleanly
      await _socket?.stop(reason: 'reconnect after resume');

      // Brief delay to ensure cleanup (socket.stop handles its own teardown)
      await Future.delayed(const Duration(milliseconds: 50));

      // Reinitiate websocket based on recording state
      if (recordingState == RecordingState.record) {
        await _initiateWebsocket(
          audioCodec: BleAudioCodec.pcm16,
          sampleRate: 16000,
          force: true,
          source: ConversationSource.phone.name,
        );
      } else if (recordingState == RecordingState.deviceRecord && _recordingDevice != null) {
        BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
        await _initiateWebsocket(audioCodec: codec, force: true, source: _getConversationSourceFromDevice());
      } else if (recordingState == RecordingState.systemAudioRecord) {
        await _initiateWebsocket(
          audioCodec: BleAudioCodec.pcm16,
          sampleRate: 16000,
          force: true,
          source: ConversationSource.desktop.name,
        );
      }

      DebugLogManager.logEvent('socket_reconnect_completed', {
        'new_state': _socket != null ? _socket!.state.name : 'null',
      });
    } finally {
      _isReconnectingAfterResume = false;
    }
  }

  /// Non-blocking wrapper for socket reconnection after resume.
  void _reconnectSocketAfterResumeAsync() async {
    try {
      await _reconnectSocketAfterResume();

      if (_socket?.state != SocketServiceState.connected) {
        debugPrint('[CaptureProvider] Immediate reconnect failed, starting keep-alive');
        _startKeepAliveServices();
      }
    } catch (e, stack) {
      DebugLogManager.logEvent('app_resumed_reconnect_error', {
        'error': e.toString(),
        'stack': stack.toString().substring(0, min(500, stack.toString().length)),
      });
      debugPrint('[CaptureProvider] Resume reconnect error: $e');
      _startKeepAliveServices();
    } finally {
      _isReconnectingSocket = false;
      _startSocketHealthMonitor(); // Start health monitor AFTER reconnection
      notifyListeners();
    }
  }

  void updateProviderInstances(ConversationProvider? cp, MessageProvider? mp, PeopleProvider? pp, UsageProvider? up) {
    conversationProvider = cp;
    messageProvider = mp;
    peopleProvider = pp;
    usageProvider = up;

    // Clean up orphan drafts from previous sessions (fire-and-forget)
    _cleanupOrphanDrafts();

    notifyListeners();
  }

  /// Cleans up orphan draft conversations from previous interrupted sessions.
  /// Non-blocking: runs in background without affecting app startup.
  void _cleanupOrphanDrafts() async {
    try {
      final userId = SupabaseAuthService.instance.maityUserId;
      if (userId == null) return;
      await OmiSupabaseService.cleanupOrphanDrafts(userId: userId);
      // Refresh conversation list if any were finalized
      conversationProvider?.refreshConversations();
    } catch (e) {
      debugPrint('[CaptureProvider] Orphan cleanup failed (non-blocking): $e');
    }
  }

  BtDevice? _recordingDevice;

  String? _getConversationSourceFromDevice() {
    if (_recordingDevice == null) {
      return null;
    }
    switch (_recordingDevice!.type) {
      case DeviceType.friendPendant:
        return 'friend_com';
      case DeviceType.omi:
        return 'omi';
      case DeviceType.fieldy:
        return 'fieldy';
      case DeviceType.bee:
        return 'bee';
      case DeviceType.plaud:
        return 'plaud';
      case DeviceType.frame:
        return 'frame';
      case DeviceType.appleWatch:
        return 'apple_watch';
      case DeviceType.limitless:
        return 'limitless';
    }
  }

  ServerConversation? _conversation;
  List<TranscriptSegment> segments = [];
  List<ConversationPhoto> photos = [];
  Map<String, SpeakerLabelSuggestionEvent> suggestionsBySegmentId = {};
  List<String> taggingSegmentIds = [];

  /// Version counter for segment changes. Widgets use Selector on this
  /// to only rebuild when segments actually change, not on every notifyListeners().
  int _segmentsVersion = 0;
  int get segmentsVersion => _segmentsVersion;

  bool hasTranscripts = false;

  StreamSubscription? _bleBytesStream;
  StreamSubscription? _blePhotoStream;

  get bleBytesStream => _bleBytesStream;

  StreamSubscription? _bleButtonStream;
  DateTime? _voiceCommandSession;
  List<List<int>> _commandBytes = [];
  bool _isProcessingButtonEvent = false; // Guard to prevent overlapping button operations

  StreamSubscription? _storageStream;

  get storageStream => _storageStream;

  RecordingState recordingState = RecordingState.stop;

  bool _isPaused = false;
  bool get isPaused => _isPaused;

  // Session-based auto-resume flag
  // Always true on app start, set to false only when user manually stops/pauses
  bool _shouldAutoResumeAfterWake = true;
  bool get shouldAutoResumeAfterWake => _shouldAutoResumeAfterWake;

  bool _transcriptServiceReady = false;

  bool get transcriptServiceReady => _transcriptServiceReady && _isConnected;

  // having a connected device or using the phone's mic for recording
  bool get recordingDeviceServiceReady =>
      _recordingDevice != null ||
      recordingState == RecordingState.record ||
      recordingState == RecordingState.systemAudioRecord;

  bool get havingRecordingDevice => _recordingDevice != null;

  BtDevice? get recordingDevice => _recordingDevice;

  void setHasTranscripts(bool value) {
    hasTranscripts = value;
    notifyListeners();
  }

  void setConversationCreating(bool value) {
    debugPrint('set Conversation creating $value');
    // ConversationCreating = value;
    notifyListeners();
  }

  void _updateRecordingDevice(BtDevice? device) {
    debugPrint('connected device changed from ${_recordingDevice?.id} to ${device?.id}');
    _recordingDevice = device;
    notifyListeners();

    // Update foreground notification when device connection changes
    _updateForegroundNotification(_getNotificationState());
  }

  void updateRecordingDevice(BtDevice? device) {
    _updateRecordingDevice(device);
  }

  Future _resetStateVariables() async {
    segments = [];
    photos = [];
    hasTranscripts = false;
    _segmentsVersion++;
    suggestionsBySegmentId = {};
    _conversation = null;
    taggingSegmentIds = [];
    // Clear audio buffer used for speaker verification
    _audioBuffer?.clearAudioBytes();
    _audioBuffer = null;
    // Reset finalized flag for next conversation
    _conversationFinalized = false;
    // Reset recovery state for new session
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _unsavedSegmentCount = 0;
    _currentSessionId = null;
    // Reset segment notify throttle
    _segmentNotifyTimer?.cancel();
    _segmentNotifyTimer = null;
    _lastSegmentNotifyTime = null;
    // Reset incremental save state
    _incrementalSave.reset();
    _totalSegmentCount = 0;
    // Reset health monitor
    _socketHealthTimer?.cancel();
    _socketHealthTimer = null;
    _lastSegmentReceivedAt = null;
    _sttReconnectAttempts = 0;
    _lastAudioBytesSentAt = null;
    // Cancel background finalize timer
    _backgroundFinalizeTimer?.cancel();
    _backgroundFinalizeTimer = null;
    CaptureProvider.isRecordingWithPhoneMic = false;
    notifyListeners();
  }

  Future<void> onRecordProfileSettingChanged() async {
    await _resetState();
  }

  /// Called when transcription settings are changed (e.g., custom STT provider)
  /// This resets the socket connection to use the new configuration
  Future<void> onTranscriptionSettingsChanged() async {
    debugPrint("Transcription settings changed, refreshing socket connection...");

    // Handle device recording
    if (_recordingDevice != null) {
      await _socket?.stop(reason: 'transcription settings changed');
      BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
      await _initiateWebsocket(
        audioCodec: codec,
        force: true,
        source: _getConversationSourceFromDevice(),
      );
      return;
    }

    // Handle phone mic recording
    if (recordingState == RecordingState.record) {
      await _socket?.stop(reason: 'transcription settings changed');
      await _initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.phone.name,
      );
      return;
    }

    // Handle system audio recording (desktop)
    if (recordingState == RecordingState.systemAudioRecord) {
      await _socket?.stop(reason: 'transcription settings changed');
      await _initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.desktop.name,
      );
      return;
    }
  }

  /// Called when VAD settings are changed
  /// This re-initializes the VAD service with new configuration
  Future<void> onVadSettingsChanged() async {
    debugPrint("VAD settings changed, reinitializing VAD service...");

    // Only reinitialize if currently recording with PCM16
    if (recordingState == RecordingState.record || recordingState == RecordingState.systemAudioRecord) {
      final customSttConfig = SharedPreferencesUtil().customSttConfig;
      final effectiveConfig = customSttConfig.isEnabled ? customSttConfig : null;
      await _initializeVadService(BleAudioCodec.pcm16, effectiveConfig);
      notifyListeners();
    }
  }

  Future<void> changeAudioRecordProfile({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    String? source,
  }) async {
    await _resetState();
    await _initiateWebsocket(
        audioCodec: audioCodec, sampleRate: sampleRate, channels: channels, isPcm: isPcm, source: source);
  }

  Future<void> _initiateWebsocket({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    bool force = false,
    String? source,
  }) async {
    Logger.debug('initiateWebsocket in capture_provider');

    BleAudioCodec codec = audioCodec;
    sampleRate ??= mapCodecToSampleRate(codec);
    channels ??= (codec == BleAudioCodec.pcm16 || codec == BleAudioCodec.pcm8) ? 1 : 2;

    Logger.debug('is ws null: ${_socket == null}');
    Logger.debug('Initiating WebSocket with: codec=$codec, sampleRate=$sampleRate, channels=$channels, isPcm=$isPcm');

    // Get language and custom STT config
    String language =
        SharedPreferencesUtil().hasSetPrimaryLanguage ? SharedPreferencesUtil().userPrimaryLanguage : "multi";
    final customSttConfig = SharedPreferencesUtil().customSttConfig;

    Logger.debug('Custom STT enabled: ${customSttConfig.isEnabled}, provider: ${customSttConfig.provider}');
    if (customSttConfig.isEnabled) {
      debugPrint('[Maity] STT key hash: ${customSttConfig.apiKey?.hashCode.toRadixString(16).padLeft(8, "0").substring(0, 8) ?? "null"}');
    }

    // Check codec compatibility for custom STT - fallback to default if incompatible
    CustomSttConfig? effectiveConfig = customSttConfig.isEnabled ? customSttConfig : null;
    if (effectiveConfig != null && !TranscriptSocketServiceFactory.isCodecSupportedForCustomStt(codec)) {
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
    _socket = await ServiceManager.instance().socket.conversation(
          codec: codec,
          sampleRate: sampleRate,
          language: language,
          force: force,
          source: source,
          customSttConfig: effectiveConfig,
        );
    if (_socket == null) {
      _captureLog.log('socket', 'websocket_creation_failed', severity: 'error', details: {
        'codec': codec.name,
        'custom_stt': effectiveConfig != null,
      });
      _startKeepAliveServices();
      debugPrint("Can not create new conversation socket");
      return;
    }
    _socket?.subscribe(this, this);
    _transcriptServiceReady = true;

    // Initialize VAD if enabled and using custom STT with PCM16 codec
    await _initializeVadService(codec, effectiveConfig);

    _loadInProgressConversation();

    notifyListeners();
  }

  /// Initialize VAD service if enabled and compatible
  Future<void> _initializeVadService(BleAudioCodec codec, CustomSttConfig? customSttConfig) async {
    // Dispose any existing VAD service
    await _vadService?.dispose();
    _vadService = null;
    vadStateNotifier.value = null;

    final vadConfig = SharedPreferencesUtil().vadConfig;

    // VAD only works with:
    // 1. VAD enabled in settings
    // 2. Custom STT enabled (direct Deepgram connection)
    // 3. PCM16 codec (VAD expects 16kHz PCM16 audio)
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

      // Set up callback to send filtered audio to socket
      _vadService!.onAudioToSend = (bytes) {
        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(bytes);
          _wsSocketBytesSent += bytes.length;
        }
      };

      _vadService!.onStateChanged = (state) {
        debugPrint('[VAD] State changed: ${state.displayName}');
        vadStateNotifier.value = state;
      };

      debugPrint('[VAD] Service initialized successfully');
    } catch (e) {
      debugPrint('[VAD] Failed to initialize: $e');
      // Continue without VAD on failure
      _vadService = null;
    }
  }

  void _processVoiceCommandBytes(String deviceId, List<List<int>> data) async {
    if (data.isEmpty) {
      debugPrint("voice frames is empty");
      return;
    }

    BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
    if (messageProvider != null) {
      await messageProvider?.sendVoiceMessageStreamToServer(
        data,
        onFirstChunkRecived: () {
          _playSpeakerHaptic(deviceId, 2);
        },
        codec: codec,
      );
    }
  }

  // Just incase the ble connection get loss
  void _watchVoiceCommands(String deviceId, DateTime session) {
    Timer.periodic(const Duration(seconds: 3), (t) async {
      debugPrint("voice command watch");
      if (session != _voiceCommandSession) {
        t.cancel();
        return;
      }
      var value = await _getBleButtonState(deviceId);
      if (value.isEmpty || value.length < 4) return;
      var buttonState = ByteData.view(Uint8List.fromList(value.sublist(0, 4).reversed.toList()).buffer).getUint32(0);
      debugPrint("watch device button $buttonState");

      // Force process
      if (buttonState == 5 && session == _voiceCommandSession) {
        _voiceCommandSession = null; // end session
        var data = List<List<int>>.from(_commandBytes);
        _commandBytes = [];
        _processVoiceCommandBytes(deviceId, data);
      }
    });
  }

  Future streamButton(String deviceId) async {
    debugPrint('streamButton in capture_provider');
    _bleButtonStream?.cancel();
    _bleButtonStream = await _getBleButtonListener(deviceId, onButtonReceived: (List<int> value) {
      final snapshot = List<int>.from(value);
      if (snapshot.isEmpty || snapshot.length < 4) return;
      var buttonState = ByteData.view(Uint8List.fromList(snapshot.sublist(0, 4).reversed.toList()).buffer).getUint32(0);
      debugPrint("device button $buttonState");

      // double tap
      if (buttonState == 2) {
        debugPrint("Double tap detected");

        // Guard: ignore if already processing a button event
        if (_isProcessingButtonEvent) {
          debugPrint("Double tap: already processing, ignoring");
          return;
        }

        if (SharedPreferencesUtil().doubleTapPausesMuting) {
          // Pause/resume recording
          debugPrint("Double tap: toggling pause/mute");
          _isProcessingButtonEvent = true;
          if (_isPaused) {
            resumeDeviceRecording().then((_) {
              _isProcessingButtonEvent = false;
            }).catchError((e) {
              debugPrint("Error resuming device recording: $e");
              _isProcessingButtonEvent = false;
            });
          } else {
            pauseDeviceRecording().then((_) {
              _isProcessingButtonEvent = false;
            }).catchError((e) {
              debugPrint("Error pausing device recording: $e");
              _isProcessingButtonEvent = false;
            });
          }
        } else {
          // End conversation and process (default)
          debugPrint("Double tap: processing conversation");
          forceProcessingCurrentConversation();
        }
        return;
      }

      // start long press (for voice commands)
      if (buttonState == 3 && _voiceCommandSession == null) {
        _voiceCommandSession = DateTime.now();
        _commandBytes = [];
        _watchVoiceCommands(deviceId, _voiceCommandSession!);
        _playSpeakerHaptic(deviceId, 1);
      }

      // release (end voice command)
      if (buttonState == 5 && _voiceCommandSession != null) {
        _voiceCommandSession = null; // end session
        var data = List<List<int>>.from(_commandBytes);
        _commandBytes = [];
        _processVoiceCommandBytes(deviceId, data);
      }
    });
  }

  Future streamAudioToWs(String deviceId, BleAudioCodec codec) async {
    debugPrint('streamAudioToWs in capture_provider');
    _captureLog.log('ble', 'audio_stream_started', details: {
      'device_id': deviceId,
      'codec': codec.name,
    });
    _bleBytesStream?.cancel();
    _startMetricsTracking();
    _bleBytesStream = await _getBleAudioBytesListener(deviceId, onAudioBytesReceived: (List<int> value) {
      final snapshot = List<int>.from(value);
      if (snapshot.isEmpty || snapshot.length < 3) return;

      // Track bytes received from BLE
      _blesBytesReceived += snapshot.length;
      _lastAudioBytesSentAt = DateTime.now();

      // Store audio for speaker verification (used when conversation ends)
      _audioBuffer?.storeFramePacket(snapshot);

      // Command button triggered
      bool voiceCommandSupported = _recordingDevice != null
          ? (_recordingDevice?.type == DeviceType.omi)
          : false;
      if (_voiceCommandSession != null && voiceCommandSupported) {
        _commandBytes.add(snapshot.sublist(3));
      }

      // Local storage syncs
      var checkWalSupported =
          (_recordingDevice?.type == DeviceType.omi) &&
              codec.isOpusSupported() &&
              (_socket?.state != SocketServiceState.connected || SharedPreferencesUtil().unlimitedLocalStorageEnabled);
      if (checkWalSupported != _isWalSupported) {
        setIsWalSupported(checkWalSupported);
      }
      if (_isWalSupported) {
        _wal.getSyncs().phone.onByteStream(snapshot);
      }

      // Send WS
      if (_socket?.state == SocketServiceState.connected) {
        final paddingLeft =
            (_recordingDevice?.type == DeviceType.omi) ? 3 : 0;
        final trimmedValue = paddingLeft > 0 ? value.sublist(paddingLeft) : value;
        _socket?.send(trimmedValue);

        // Track bytes sent to websocket
        _wsSocketBytesSent += trimmedValue.length;

        // Mark as synced
        if (_isWalSupported) {
          _wal.getSyncs().phone.onBytesSync(value);
        }
      }
    });
    notifyListeners();
  }

  Future<void> _resetState() async {
    debugPrint('resetState');
    await _cleanupCurrentState();

    // Always try to stream audio if a device is present
    await _ensureDeviceSocketConnection();
    await _initiateDeviceAudioStreaming();

    // Additionally, stream photos if the device supports it
    if (_recordingDevice != null) {
      var connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      if (connection != null && await connection.hasPhotoStreamingCharacteristic()) {
        await _initiateDevicePhotoStreaming();
      }
    }

    notifyListeners();
  }

  Future _cleanupCurrentState() async {
    _cancelSilenceTimer();
    await _closeBleStream();

    // Flush and dispose VAD service
    _vadService?.flush();
    if (_vadService != null) {
      debugPrint('[VAD] Final metrics: ${_vadService!.metrics}');
    }
    await _vadService?.dispose();
    _vadService = null;
    vadStateNotifier.value = null;

    notifyListeners();
  }

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return BleAudioCodec.pcm8;
    }
    return connection.getAudioCodec();
  }

  Future<bool> _playSpeakerHaptic(String deviceId, int level) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return false;
    }
    return connection.performPlayToSpeakerHaptic(level);
  }

  Future<StreamSubscription?> _getBleAudioBytesListener(
    String deviceId, {
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
  }

  Future<StreamSubscription?> _getBleButtonListener(
    String deviceId, {
    required void Function(List<int>) onButtonReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleButtonListener(onButtonReceived: onButtonReceived);
  }

  Future<List<int>> _getBleButtonState(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(<int>[]);
    }
    return connection.getBleButtonState();
  }

  Future<void> _ensureDeviceSocketConnection() async {
    if (_recordingDevice == null) {
      return;
    }
    BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
    var language =
        SharedPreferencesUtil().hasSetPrimaryLanguage ? SharedPreferencesUtil().userPrimaryLanguage : "multi";
    final customSttConfig = SharedPreferencesUtil().customSttConfig;
    final sttConfigId = customSttConfig.sttConfigId;

    if (language != _socket?.language ||
        codec != _socket?.codec ||
        _socket?.state != SocketServiceState.connected ||
        _socket?.sttConfigId != sttConfigId) {
      await _initiateWebsocket(audioCodec: codec, force: true, source: _getConversationSourceFromDevice());
    }
  }

  Future<void> _initiateDeviceAudioStreaming() async {
    final device = _recordingDevice;
    if (device == null) {
      return;
    }
    final deviceId = device.id;
    if (deviceId.isEmpty) {
      return;
    }
    final connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return;
    final codec = await _getAudioCodec(deviceId);
    await _wal.getSyncs().phone.onAudioCodecChanged(codec);

    // Set device info for WAL creation
    final pd = await device.getDeviceInfo(connection);
    final deviceModel = pd.modelNumber.isNotEmpty ? pd.modelNumber : "Maity";
    _wal.getSyncs().phone.setDeviceInfo(deviceId, deviceModel);

    // Initialize audio buffer for speaker verification
    // framesPerSecond depends on codec: opus typically sends ~50 frames/sec
    _audioBuffer = WavBytesUtil(codec: codec, framesPerSecond: 50);
    debugPrint('[Maity] Audio buffer initialized for speaker verification');

    await streamButton(deviceId);
    await streamAudioToWs(deviceId, codec);

    // Update state
    updateRecordingState(RecordingState.deviceRecord);
    notifyListeners();
  }

  Future<void> _initiateDevicePhotoStreaming() async {
    if (_recordingDevice == null) return;
    final deviceId = _recordingDevice!.id;
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return;

    await connection.performCameraStartPhotoController();
    _blePhotoStream = await connection.performGetImageListener(onImageReceived: (orientedImage) async {
      final rotatedImageBytes = rotateImage(orientedImage);
      final String tempId = 'temp_img_${DateTime.now().millisecondsSinceEpoch}';
      final String base64Image = base64Encode(rotatedImageBytes);

      // Add placeholder to UI for immediate feedback
      photos.add(ConversationPhoto(id: tempId, base64: base64Image, createdAt: DateTime.now()));
      photos = List.from(photos);
      notifyListeners();

      // Chunking Logic
      const int chunkSize = 8192; // 8KB chunks
      final totalChunks = (base64Image.length / chunkSize).ceil();

      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize > base64Image.length) ? base64Image.length : start + chunkSize;
        final chunk = base64Image.substring(start, end);

        final payload = jsonEncode({
          'type': 'image_chunk',
          'id': tempId,
          'index': i,
          'total': totalChunks,
          'data': chunk,
        });

        if (_socket?.state == SocketServiceState.connected) {
          _socket?.send(payload); // Send the JSON string
        }
        await Future.delayed(const Duration(milliseconds: 20)); // Small delay to prevent flooding
      }
    });
    notifyListeners();
  }

  /// Enter speech profile mode - blocks conversation saves during voice training
  void enterSpeechProfileMode() {
    debugPrint('[Maity] Entering speech profile mode');
    _isSpeechProfileMode = true;
    _silenceTimer?.cancel();
  }

  /// Exit speech profile mode - allows normal conversation saves again
  void exitSpeechProfileMode() {
    debugPrint('[Maity] Exiting speech profile mode');
    _isSpeechProfileMode = false;
    segments.clear();
    _resetStateVariables();
  }

  void clearTranscripts() {
    segments = [];
    hasTranscripts = false;
    _segmentsVersion++;
    notifyListeners();
  }

  void _startMetricsTracking() {
    _blesBytesReceived = 0;
    _wsSocketBytesSent = 0;
    _bleReceiveRateKbps = 0.0;
    _wsSendRateKbps = 0.0;
    _metricsLastCalculated = DateTime.now();

    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _calculateMetricsRates();
    });
  }

  void _calculateMetricsRates() {
    final now = DateTime.now();
    if (_metricsLastCalculated == null) {
      _metricsLastCalculated = now;
      return;
    }

    final elapsedSeconds = now.difference(_metricsLastCalculated!).inMilliseconds / 1000.0;
    if (elapsedSeconds > 0) {
      // Calculate kbps (kilobits per second)
      final newBleRate = (_blesBytesReceived * 8) / (elapsedSeconds * 1000);
      final newWsRate = (_wsSocketBytesSent * 8) / (elapsedSeconds * 1000);
      final rateChanged = (newBleRate - _bleReceiveRateKbps).abs() > 0.1 ||
          (newWsRate - _wsSendRateKbps).abs() > 0.1;

      _bleReceiveRateKbps = newBleRate;
      _wsSendRateKbps = newWsRate;

      // Log metrics every 30s (every 6th call since timer runs every 5s)
      _metricsLogCounter++;
      if (_metricsLogCounter >= 6) {
        _metricsLogCounter = 0;
        _captureLog.log('metrics', 'metrics_snapshot', severity: 'debug', details: {
          'ble_kbps': double.parse(_bleReceiveRateKbps.toStringAsFixed(2)),
          'ws_kbps': double.parse(_wsSendRateKbps.toStringAsFixed(2)),
          'audio_bytes_sent': _audioBytesSent,
        });
      }

      // Reset counters for next interval
      _blesBytesReceived = 0;
      _wsSocketBytesSent = 0;
      _metricsLastCalculated = now;

      if (rateChanged) {
        notifyListeners();
      }
    }
  }

  void _stopMetricsTracking() {
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _blesBytesReceived = 0;
    _wsSocketBytesSent = 0;
    _bleReceiveRateKbps = 0.0;
    _wsSendRateKbps = 0.0;
    _metricsLastCalculated = null;
    notifyListeners();
  }

  Future _closeBleStream() async {
    _captureLog.log('ble', 'audio_stream_closed');
    await _bleBytesStream?.cancel();
    await _blePhotoStream?.cancel();
    _stopMetricsTracking();
    if (_recordingDevice != null) {
      var connection = await ServiceManager.instance().device.ensureConnection(_recordingDevice!.id);
      if (connection != null && await connection.hasPhotoStreamingCharacteristic()) {
        await connection.performCameraStopPhotoController();
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    debugPrint('[CaptureProvider] dispose() called');

    // Cancel ALL timers to prevent memory leaks and zombie timers
    _bleBytesStream?.cancel();
    _blePhotoStream?.cancel();
    _keepAliveTimer?.cancel();
    _connectionStateListener?.cancel();
    _recordingTimer?.cancel();
    _metricsTimer?.cancel();
    _recoveryTimer?.cancel();
    _silenceTimer?.cancel();
    _socketHealthTimer?.cancel();  // Health monitor timer
    _reconnectTimer?.cancel();     // Auto-reconnect timer
    _backgroundFinalizeTimer?.cancel();  // Background finalize timer
    _segmentNotifyTimer?.cancel();       // Segment notify throttle timer

    // Dispose VAD service
    _vadService?.dispose();
    _vadService = null;
    vadStateNotifier.value = null;

    // Stop socket BEFORE unsubscribing to ensure clean shutdown
    _socket?.stop(reason: 'provider disposed');
    _socket?.unsubscribe(this);

    // Remove lifecycle observer on ALL platforms (was registered in constructor)
    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  void updateRecordingState(RecordingState state) {
    recordingState = state;
    notifyListeners();
    _broadcastRecordingState();

    // Update foreground notification with appropriate state
    _updateForegroundNotification(_getNotificationState());
  }

  streamRecording() async {
    updateRecordingState(RecordingState.initialising);
    await Permission.microphone.request();

    // Track when recording started for local conversations
    _recordingStartTime = DateTime.now();
    // Generate session ID for recovery
    _currentSessionId = const Uuid().v4();

    _captureLog.startSession(
      _currentSessionId!,
      getRecordingState: () => recordingState.name,
      getSegmentCount: () => segments.length,
      getSocketState: _socketStateName,
    );
    _captureLog.log('recording', 'recording_started', details: {
      'source': 'phone_mic',
      'codec': 'pcm16',
      'sample_rate': 16000,
    });

    // Start health monitor for transcription stall detection
    _startSocketHealthMonitor();

    // prepare
    await changeAudioRecordProfile(audioCodec: BleAudioCodec.pcm16, sampleRate: 16000);

    // record
    _audioBytesSent = 0;
    await ServiceManager.instance().mic.start(onByteReceived: (bytes) {
      _lastAudioBytesSentAt = DateTime.now();
      if (_socket?.state == SocketServiceState.connected) {
        // Use VAD to filter silence if available
        if (_vadService != null && _vadService!.isInitialized) {
          // VAD will call onAudioToSend callback when speech detected
          _vadService!.processAudioFrame(Uint8List.fromList(bytes));
        } else {
          // No VAD - send all audio directly
          _socket?.send(bytes);
        }
        _audioBytesSent += bytes.length;
        if (_audioBytesSent % 32000 < bytes.length) {
          debugPrint('[Maity] Audio bytes enviados: $_audioBytesSent');
        }
      }
    }, onRecording: () {
      CaptureProvider.isRecordingWithPhoneMic = true;
      updateRecordingState(RecordingState.record);
    }, onStop: () {
      CaptureProvider.isRecordingWithPhoneMic = false;
      updateRecordingState(RecordingState.stop);
    }, onInitializing: () {
      updateRecordingState(RecordingState.initialising);
    });
  }

  stopStreamRecording() async {
    CaptureProvider.isRecordingWithPhoneMic = false;
    _cancelSilenceTimer(); // Prevent silence timeout from interfering with finalize
    _captureLog.log('recording', 'recording_stop_requested', details: {'source': 'phone_mic'});
    _stopSocketHealthMonitor();
    // Finalize local conversation before stopping (for custom STT mode)
    await _finalizeLocalConversation();

    await _cleanupCurrentState();
    ServiceManager.instance().mic.stop();
    updateRecordingState(RecordingState.stop);
    await _socket?.stop(reason: 'stop stream recording');
    _captureLog.endSession();
  }

  Future streamDeviceRecording({BtDevice? device}) async {
    debugPrint("streamDeviceRecording $device");
    if (device != null) _updateRecordingDevice(device);

    // Track when recording started for local conversations
    _recordingStartTime = DateTime.now();
    // Generate session ID for recovery
    _currentSessionId = const Uuid().v4();

    _captureLog.startSession(
      _currentSessionId!,
      getRecordingState: () => recordingState.name,
      getSegmentCount: () => segments.length,
      getSocketState: _socketStateName,
    );
    _captureLog.log('recording', 'recording_started', details: {
      'source': 'ble_device',
      'device_id': device?.id,
      'device_name': device?.name,
      'device_type': device?.type.name,
    });

    // Start health monitor for transcription stall detection
    _startSocketHealthMonitor();

    bool wasPaused = _isPaused;

    await _resetStateVariables();
    await _resetState();

    if (wasPaused) {
      await pauseDeviceRecording();
    }
  }

  Future stopStreamDeviceRecording({bool cleanDevice = false}) async {
    _cancelSilenceTimer(); // Prevent silence timeout from interfering with finalize
    _captureLog.log('recording', 'recording_stop_requested', details: {'source': 'ble_device'});
    _stopSocketHealthMonitor();
    // Finalize local conversation before stopping (for custom STT mode)
    await _finalizeLocalConversation();

    await _cleanupCurrentState();
    if (cleanDevice) {
      _updateRecordingDevice(null);
    }
    updateRecordingState(RecordingState.stop);
    await _socket?.stop(reason: 'stop stream device recording');
    _captureLog.endSession();
  }

  Future<void> streamSystemAudioRecording() async {
    if (!PlatformService.isDesktop) {
      notifyError('System audio recording is only available on macOS and Windows.');
      return;
    }

    // Track when recording started for local conversations
    _recordingStartTime = DateTime.now();
    // Generate session ID for recovery
    _currentSessionId = const Uuid().v4();

    _captureLog.startSession(
      _currentSessionId!,
      getRecordingState: () => recordingState.name,
      getSegmentCount: () => segments.length,
      getSocketState: _socketStateName,
    );
    _captureLog.log('recording', 'recording_started', details: {
      'source': 'system_audio',
      'codec': 'pcm16',
      'sample_rate': 16000,
    });

    // Start health monitor for transcription stall detection
    _startSocketHealthMonitor();

    // User wants to record - enable auto-resume after wake
    _shouldAutoResumeAfterWake = true;

    updateRecordingState(RecordingState.initialising);

    _systemAudioBuffer = [];
    _systemAudioCaching = true;
    Future.delayed(const Duration(seconds: 3), () {
      _systemAudioCaching = false;
      _flushSystemAudioBuffer();
    });

    bool permissionsGranted = await _checkAndRequestSystemAudioPermissions();
    if (permissionsGranted) {
      await _startSystemAudioCapture();
    } else {
      updateRecordingState(RecordingState.stop);
    }
  }

  Future<void> _startSystemAudioCapture() async {
    await changeAudioRecordProfile(audioCodec: BleAudioCodec.pcm16, sampleRate: 16000);

    await ServiceManager.instance().systemAudio.start(
          onFormatReceived: (Map<String, dynamic> format) async {
            // This callback is for information only, no action needed.
          },
          onByteReceived: _processSystemAudioByteReceived,
          onRecording: () {
            updateRecordingState(RecordingState.systemAudioRecord);
            _startRecordingTimer();
            debugPrint('System audio recording started successfully.');
          },
          onStop: () {
            if (_isPaused) {
              updateRecordingState(RecordingState.pause);
            } else {
              updateRecordingState(RecordingState.stop);
            }
            _socket?.stop(reason: 'system audio stream ended from native');
          },
          onError: (error) {
            debugPrint('System audio capture error: $error');
            AppSnackbar.showSnackbarError('An error occurred during recording: $error');
            updateRecordingState(RecordingState.stop);
          },
          onSystemWillSleep: (wasRecording) {
            debugPrint('System will sleep - was recording: $wasRecording');
          },
          onSystemDidWake: (nativeIsRecording) async {
            debugPrint('[SystemWake] Native recording: $nativeIsRecording, Flutter state: $recordingState');

            if (!nativeIsRecording && recordingState == RecordingState.systemAudioRecord) {
              // Native stopped, sync Flutter state
              updateRecordingState(RecordingState.stop);

              // Auto-resume based on session flag (was recording before sleep?)
              if (_shouldAutoResumeAfterWake) {
                debugPrint('[SystemWake] Auto-resuming recording (was recording before sleep)...');
                await Future.delayed(const Duration(seconds: 2));
                await streamSystemAudioRecording();
              } else {
                debugPrint('[SystemWake] Not auto-resuming (user manually stopped)');
              }
            }
          },
          onScreenDidLock: (wasRecording) {
            debugPrint('Screen locked - was recording: $wasRecording');
          },
          onScreenDidUnlock: () {
            debugPrint('Screen unlocked');
          },
          onDisplaySetupInvalid: (reason) {
            debugPrint('Display setup invalid: $reason');
            if (recordingState == RecordingState.systemAudioRecord) {
              updateRecordingState(RecordingState.stop);
              AppSnackbar.showSnackbarError(
                  'Recording stopped: $reason. You may need to reconnect external displays or restart recording.');
            }
          },
          onMicrophoneDeviceChanged: _onMicrophoneDeviceChanged,
          onMicrophoneStatus: _onMicrophoneStatus,
        );
  }

  Future<bool> _checkAndRequestSystemAudioPermissions() async {
    final micStatus = await _screenCaptureChannel.invokeMethod('checkMicrophonePermission');

    if (micStatus != 'granted') {
      if (micStatus == 'undetermined' || micStatus == 'unavailable') {
        final granted = await _screenCaptureChannel.invokeMethod('requestMicrophonePermission');
        if (!granted) {
          AppSnackbar.showSnackbarError('Microphone permission required');
          return false;
        }
      } else if (micStatus == 'denied') {
        AppSnackbar.showSnackbarError('Grant microphone permission in System Preferences');
        return false;
      }
    }

    final screenStatus = await _screenCaptureChannel.invokeMethod('checkScreenCapturePermission');

    if (screenStatus != 'granted') {
      final granted = await _screenCaptureChannel.invokeMethod('requestScreenCapturePermission');
      if (!granted) {
        AppSnackbar.showSnackbarError('Screen recording permission required');
        return false;
      }
    }
    return true;
  }

  Future<void> _onMicrophoneDeviceChanged() async {
    final nativeRecording = await _screenCaptureChannel.invokeMethod('isRecording') ?? false;
    if (!nativeRecording) return;

    _isAutoReconnecting = true;
    _reconnectCountdown = 5;
    notifyListeners();

    await pauseSystemAudioRecording(isAuto: true);

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_reconnectCountdown > 1) {
        _reconnectCountdown--;
        notifyListeners();
      } else {
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        if (_isAutoReconnecting) {
          resumeSystemAudioRecording().then((_) {
            _isAutoReconnecting = false;
            notifyListeners();
          });
        }
      }
    });
  }

  void _onMicrophoneStatus(String deviceName, double micLevel, double systemAudioLevel) {
    final bool needsUpdate = microphoneName != deviceName ||
        (microphoneLevel - micLevel).abs() > 0.001 ||
        (this.systemAudioLevel - systemAudioLevel).abs() > 0.001;

    if (needsUpdate) {
      microphoneName = deviceName;
      microphoneLevel = micLevel;
      this.systemAudioLevel = systemAudioLevel;
      notifyListeners();
    }
  }

  void _flushSystemAudioBuffer() {
    if (_socket?.state == SocketServiceState.connected) {
      // VAD expects 512 samples (1024 bytes) at 16kHz
      // System audio comes in smaller chunks, so we accumulate
      const frameSize = 1024; // 512 samples * 2 bytes per sample (PCM16)
      while (_systemAudioBuffer.length >= frameSize) {
        final chunk = _systemAudioBuffer.sublist(0, frameSize);

        // Use VAD to filter silence if available
        if (_vadService != null && _vadService!.isInitialized) {
          // VAD will call onAudioToSend callback when speech detected
          _vadService!.processAudioFrame(Uint8List.fromList(chunk));
        } else {
          // No VAD - send all audio directly
          _socket?.send(chunk);
        }

        _systemAudioBuffer.removeRange(0, frameSize);
      }
    }
  }

  Future<void> stopSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;

    _captureLog.log('recording', 'recording_stop_requested', details: {'source': 'system_audio'});
    _stopSocketHealthMonitor();
    // Finalize local conversation before stopping (for custom STT mode)
    await _finalizeLocalConversation();

    // User manually stopped - don't auto-resume after wake
    _shouldAutoResumeAfterWake = false;

    _isAutoReconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    ServiceManager.instance().systemAudio.stop();
    _isPaused = false;
    _stopRecordingTimer();
    await _socket?.stop(reason: 'manual stop');
    await _cleanupCurrentState();
    _captureLog.endSession();
  }

  Future<void> pauseSystemAudioRecording({bool isAuto = false}) async {
    if (!PlatformService.isDesktop) return;

    if (!isAuto) {
      // User manually paused - don't auto-resume after wake
      _shouldAutoResumeAfterWake = false;
      _isAutoReconnecting = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }

    ServiceManager.instance().systemAudio.stop();
    _isPaused = true;
    notifyListeners();
    _broadcastRecordingState();
  }

  Future<void> resumeSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;

    // User wants to resume - enable auto-resume after wake
    _shouldAutoResumeAfterWake = true;
    _isPaused = false;
    await streamSystemAudioRecording();
    _broadcastRecordingState();
  }

  Future<void> _handleFloatingControlBarMethodCall(MethodCall call) async {
    if (!PlatformService.isDesktop) return;

    switch (call.method) {
      case 'togglePauseResume':
        if (isPaused) {
          await resumeSystemAudioRecording();
        } else if (recordingState == RecordingState.systemAudioRecord) {
          await pauseSystemAudioRecording();
        } else {
          await streamSystemAudioRecording();
        }
        break;
      default:
        Logger.debug('FloatingControlBarChannel: Unhandled method ${call.method}');
    }
  }

  @override
  void onClosed([int? closeCode]) {
    _captureLog.log('socket', 'socket_closed', severity: 'warning', details: {
      'close_code': closeCode,
      'is_reconnecting_after_resume': _isReconnectingAfterResume,
    });
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;

    if (closeCode == 4002) {
      usageProvider?.markAsOutOfCreditsAndRefresh();
    }

    // Skip notifyListeners + keep-alive during intentional reconnection after resume
    // to avoid cascading reconnections that saturate the event loop
    if (!_isReconnectingAfterResume) {
      notifyListeners();
      _startKeepAliveServices();
    }
  }

  void _startKeepAliveServices() {
    _captureLog.log('socket', 'keepalive_started');
    _keepAliveTimer?.cancel();
    _keepAliveAttempts = 0;  // Reset counter when starting keep-alive

    _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (t) async {
      _keepAliveAttempts++;

      DebugLogManager.logEvent('keep_alive_tick', {
        'attempt': _keepAliveAttempts,
        'max_attempts': _maxKeepAliveAttempts,
        'socket_ready': recordingDeviceServiceReady,
        'socket_state': _socket != null ? _socket!.state.name : 'null',
        'recording_state': recordingState.name,
      });

      debugPrint("[Provider] keep alive - attempt $_keepAliveAttempts/$_maxKeepAliveAttempts");

      // Check if max attempts reached
      if (_keepAliveAttempts >= _maxKeepAliveAttempts) {
        DebugLogManager.logEvent('keep_alive_max_reached', {
          'attempts': _keepAliveAttempts,
        });
        debugPrint("[Provider] keep alive - max attempts reached, stopping");
        t.cancel();
        _keepAliveTimer = null;
        // Auto-finalize conversation with existing segments instead of going zombie
        _autoFinalizeOnConnectionLost();
        return;
      }

      // rate 1/15s
      if (_keepAliveLastExecutedAt != null &&
          DateTime.now().subtract(const Duration(seconds: 15)).isBefore(_keepAliveLastExecutedAt!)) {
        debugPrint("[Provider] keep alive - hitting rate limits 1/15s");
        return;
      }

      _keepAliveLastExecutedAt = DateTime.now();

      // If socket is already connected or no recording device, stop keep-alive
      if (!recordingDeviceServiceReady || _socket?.state == SocketServiceState.connected) {
        debugPrint("[Provider] keep alive - socket ready or connected, stopping");
        t.cancel();
        _keepAliveTimer = null;
        _keepAliveAttempts = 0;  // Reset for next time
        return;
      }

      if (_recordingDevice != null) {
        BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
        await _initiateWebsocket(audioCodec: codec, source: _getConversationSourceFromDevice());
        return;
      }
      if (recordingState == RecordingState.record) {
        await _initiateWebsocket(
            audioCodec: BleAudioCodec.pcm16, sampleRate: 16000, source: ConversationSource.phone.name);
        return;
      }
      if (recordingState == RecordingState.systemAudioRecord && PlatformService.isDesktop) {
        debugPrint("System audio socket disconnected, reconnecting...");
        await _initiateWebsocket(
            audioCodec: BleAudioCodec.pcm16, sampleRate: 16000, source: ConversationSource.desktop.name);
        return;
      }
    });
  }

  @override
  void onError(Object err) {
    _captureLog.log('socket', 'socket_error', severity: 'error', details: {
      'error': err.toString(),
    });
    _transcriptionServiceStatuses = [];
    _transcriptServiceReady = false;

    if (err.toString().contains('Failed to find any displays or windows to capture')) {
      if (recordingState == RecordingState.systemAudioRecord) {
        AppSnackbar.showSnackbarError('Display detection failed. Recording stopped.');
        updateRecordingState(RecordingState.stop);
      }
    }

    notifyListeners();
    _startKeepAliveServices();
  }

  @override
  void onConnected() {
    _captureLog.log('socket', 'socket_connected');
    _transcriptServiceReady = true;
    notifyListeners();
  }

  Future refreshInProgressConversations() async {
    _loadInProgressConversation();
  }

  Future _loadInProgressConversation() async {
    var convos = await getConversations(statuses: [ConversationStatus.in_progress], limit: 1);
    _conversation = convos.isNotEmpty ? convos.first : null;
    if (_conversation != null) {
      segments = _conversation!.transcriptSegments;
      photos = _conversation!.photos;
    }
    // NOTE: No resetear segments/photos si no hay conversación en servidor
    // Los segmentos locales (custom STT) se acumulan correctamente sin servidor
    setHasTranscripts(segments.isNotEmpty);
    notifyListeners();
  }

  @override
  void onMessageEventReceived(MessageEvent event) {
    if (event is ConversationProcessingStartedEvent) {
      conversationProvider!.addProcessingConversation(event.memory);
      _resetStateVariables();
      return;
    }

    if (event is ConversationEvent) {
      event.memory.isNew = true;
      conversationProvider!.removeProcessingConversation(event.memory.id);
      _processConversationCreated(event.memory, event.messages.cast<ServerMessage>());
      return;
    }

    if (event is LastConversationEvent) {
      _handleLastConvoEvent(event.memoryId);
      return;
    }

    if (event is SpeakerLabelSuggestionEvent) {
      _handleSpeakerLabelSuggestionEvent(event);
      return;
    }

    if (event is TranslationEvent) {
      _handleTranslationEvent(event.segments);
      return;
    }

    if (event is MessageServiceStatusEvent) {
      _transcriptionServiceStatuses.add(event);
      _transcriptionServiceStatuses = List.from(_transcriptionServiceStatuses);
      notifyListeners();
      return;
    }

    if (event is PhotoProcessingEvent) {
      final tempId = event.tempId;
      final permanentId = event.photoId;
      final photoIndex = photos.indexWhere((p) => p.id == tempId);
      if (photoIndex != -1) {
        photos[photoIndex].id = permanentId;
        notifyListeners();
      }
      return;
    }

    if (event is PhotoDescribedEvent) {
      final photoId = event.photoId;
      final description = event.description;
      final discarded = event.discarded;
      final photoIndex = photos.indexWhere((p) => p.id == photoId);
      if (photoIndex != -1) {
        photos[photoIndex].description = description;
        photos[photoIndex].discarded = discarded;
        notifyListeners();
      }
      return;
    }
  }

  Future<void> forceProcessingCurrentConversation() async {
    // Use local/Supabase flow instead of api.omi.me which fails with 401
    debugPrint('[Maity] Force processing conversation via local/Supabase flow');
    // IMPORTANT: Save BEFORE resetting state, otherwise segments will be empty
    await _finalizeLocalConversation();
    if (!_finalizeInProgress) {
      _resetStateVariables();
    }
  }

  Future<void> _processConversationCreated(ServerConversation? conversation, List<ServerMessage> messages) async {
    if (conversation == null) return;
    conversationProvider?.upsertConversation(conversation);
    MixpanelManager().conversationCreated(conversation);
  }

  Future<void> _handleLastConvoEvent(String memoryId) async {
    bool conversationExists =
        conversationProvider?.conversations.any((conversation) => conversation.id == memoryId) ?? false;
    if (conversationExists) {
      return;
    }
    ServerConversation? conversation = await getConversationById(memoryId);
    if (conversation != null) {
      debugPrint("Adding last conversation to conversations: $memoryId");
      conversationProvider?.upsertConversation(conversation);
    } else {
      debugPrint("Failed to fetch last conversation: $memoryId");
    }
  }

  void _handleTranslationEvent(List<TranscriptSegment> translatedSegments) {
    try {
      if (translatedSegments.isEmpty) return;

      debugPrint("Received ${translatedSegments.length} translated segments");

      // Update the segments with the translated ones
      var remainSegments = TranscriptSegment.updateSegments(segments, translatedSegments);
      if (remainSegments.isNotEmpty) {
        debugPrint("Adding ${remainSegments.length} new translated segments");
      }

      notifyListeners();
    } catch (e) {
      debugPrint("Error handling translation event: $e");
    }
  }

  void _handleSpeakerLabelSuggestionEvent(SpeakerLabelSuggestionEvent event) {
    // Tagging
    if (taggingSegmentIds.contains(event.segmentId)) {
      return;
    }
    // If segment already exists, check if it's assigned. If so, ignore suggestion.
    var segment = segments.firstWhereOrNull((s) => s.id == event.segmentId);
    if (segment != null && segment.id.isNotEmpty && (segment.personId != null || segment.isUser)) {
      return;
    }

    // Auto-accept if enabled for new person suggestions
    if (SharedPreferencesUtil().autoCreateSpeakersEnabled) {
      assignSpeakerToConversation(event.speakerId, event.personId, event.personName, [event.segmentId]);
    } else {
      // Otherwise, store suggestion to be displayed.
      suggestionsBySegmentId[event.segmentId] = event;
      notifyListeners();
    }
  }

  Future<void> assignSpeakerToConversation(
      int speakerId, String personId, String personName, List<String> segmentIds) async {
    if (segmentIds.isEmpty) return;

    taggingSegmentIds = List.from(segmentIds);
    notifyListeners();

    try {
      String finalPersonId = personId;

      // Create person if new
      if (finalPersonId.isEmpty) {
        Person? newPerson = await peopleProvider?.createPersonProvider(personName);
        if (newPerson != null) {
          finalPersonId = newPerson.id;
        }
      }

      // Find conversation id
      if (_conversation == null) return;

      final isAssigningToUser = finalPersonId == 'user';

      // Update local state for all segments with this speakerId
      for (var segment in segments) {
        if (segmentIds.contains(segment.id)) {
          segment.isUser = isAssigningToUser;
          segment.personId = isAssigningToUser ? null : finalPersonId;
        }
      }

      // Persist change
      await assignBulkConversationTranscriptSegments(
        _conversation!.id,
        segmentIds,
        isUser: isAssigningToUser,
        personId: isAssigningToUser ? null : finalPersonId,
      );

      // Notify backend session
      if (_socket?.state == SocketServiceState.connected) {
        final payload = jsonEncode({
          'type': 'speaker_assigned',
          'speaker_id': speakerId,
          'person_id': finalPersonId,
          'person_name': personName,
          'segment_ids': segmentIds,
        });
        _socket?.send(payload);
      }

      // Remove all suggestions for this speakerId
      suggestionsBySegmentId.removeWhere((key, value) => value.speakerId == speakerId);
    } finally {
      taggingSegmentIds = [];
      notifyListeners();
    }
  }

  @override
  void onSegmentReceived(List<TranscriptSegment> newSegments) {
    _processNewSegmentReceived(newSegments);
  }

  /// Throttled notifyListeners for segment updates.
  /// Ensures at most ~3 rebuilds per second during rapid speech.
  void _notifySegmentUpdate() {
    final now = DateTime.now();
    if (_lastSegmentNotifyTime == null ||
        now.difference(_lastSegmentNotifyTime!) >= _segmentNotifyMinInterval) {
      _lastSegmentNotifyTime = now;
      _segmentNotifyTimer?.cancel();
      _segmentNotifyTimer = null;
      notifyListeners();
    } else {
      // Schedule a deferred notification to guarantee the final update fires
      _segmentNotifyTimer?.cancel();
      _segmentNotifyTimer = Timer(
        _segmentNotifyMinInterval - now.difference(_lastSegmentNotifyTime!),
        () {
          _lastSegmentNotifyTime = DateTime.now();
          _segmentNotifyTimer = null;
          notifyListeners();
        },
      );
    }
  }

  void _processNewSegmentReceived(List<TranscriptSegment> newSegments) async {
    if (newSegments.isEmpty) return;

    debugPrint('[CaptureProvider] Received ${newSegments.length} new segments, current total: ${segments.length}');

    if (segments.isEmpty) {
      _captureLog.log('segment', 'first_segment_received', details: {
        'new_count': newSegments.length,
      });
      if (!PlatformService.isDesktop) {
        FlutterForegroundTask.sendDataToTask(jsonEncode({'location': true}));
      }
      await _loadInProgressConversation();
    }

    _captureLog.log('segment', 'segments_received', severity: 'debug', details: {
      'new_count': newSegments.length,
      'total': segments.length + newSegments.length,
    });

    final remainSegments = TranscriptSegment.updateSegments(segments, newSegments);
    segments.addAll(remainSegments);
    _totalSegmentCount += remainSegments.length;

    // Fusionar segmentos consecutivos del mismo speaker con gap < 3 segundos
    TranscriptSegment.mergeConsecutiveSegmentsByTime(segments);
    _segmentsVersion++;

    debugPrint('[CaptureProvider] After update: ${segments.length} total segments (produced: $_totalSegmentCount)');
    hasTranscripts = true;

    // Update health monitor timestamp
    _lastSegmentReceivedAt = DateTime.now();
    _sttReconnectAttempts = 0;

    // Reset silence timer (auto-save after N seconds of no speech)
    _resetSilenceTimer();

    // Schedule recovery save (debounced)
    _scheduleRecoverySave();

    // Schedule incremental save to Supabase (debounced)
    _scheduleIncrementalSave();

    // Trim old segments that have been confirmed saved to Supabase
    _trimSavedSegments();

    _notifySegmentUpdate();
  }

  void onConnectionStateChanged(bool isConnected) {
    _captureLog.log('recording', 'connection_state_changed', details: {
      'is_connected': isConnected,
    });
    _isConnected = isConnected;
    notifyListeners();
  }

  void setIsWalSupported(bool value) {
    _isWalSupported = value;
    notifyListeners();
  }

  void _processSystemAudioByteReceived(Uint8List bytes) {
    _systemAudioBuffer.addAll(bytes);
    if (!_systemAudioCaching) {
      _flushSystemAudioBuffer();
    }
  }

  void _broadcastRecordingState() {
    if (!PlatformService.isDesktop) return;

    final stateData = {
      'isRecording':
          recordingState == RecordingState.systemAudioRecord || recordingState == RecordingState.deviceRecord,
      'isPaused': _isPaused,
      'duration': _getRecordingDuration(),
      'isInitialising': recordingState == RecordingState.initialising,
    };

    _controlBarChannel.invokeMethod('updateRecordingState', stateData);
  }

  /// Updates the foreground service notification with the current state.
  /// States: 'waiting', 'device_connected', 'phone_mic', 'recording', 'processing', 'ready'
  void _updateForegroundNotification(String state) {
    if (PlatformService.isDesktop) return;

    final lang = SharedPreferencesUtil().appLanguage;
    FlutterForegroundTask.sendDataToTask(jsonEncode({
      'type': 'notification',
      'state': state,
      'lang': lang,
    }));
    debugPrint('[ForegroundNotification] Sent state=$state, lang=$lang');
  }

  /// Determines the appropriate notification state based on current provider state
  String _getNotificationState() {
    // Recording states take priority - but verify device exists for deviceRecord
    if (recordingState == RecordingState.record ||
        (recordingState == RecordingState.deviceRecord && _recordingDevice != null) ||
        recordingState == RecordingState.systemAudioRecord) {
      return 'recording';
    }
    if (recordingState == RecordingState.initialising) {
      return 'processing';
    }

    // Device connected but not recording
    if (_recordingDevice != null) {
      return 'device_connected';
    }

    // Fallback to waiting
    return 'waiting';
  }

  void _startRecordingTimer() {
    _recordingDuration = 0;
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (recordingState == RecordingState.systemAudioRecord || recordingState == RecordingState.deviceRecord) {
        _recordingDuration++;
        _broadcastRecordingState();
      }
    });
  }

  void _stopRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingDuration = 0;
  }

  /// Finalizes and saves a local conversation when using custom STT (Direct Deepgram)
  /// This is called when recording stops and we're not using the Omi backend
  /// Includes retry logic for resilience against network errors.
  Future<void> _finalizeLocalConversation() async {
    // Block saving during speech profile training
    if (_isSpeechProfileMode) {
      debugPrint('[Finalize] SKIP: Speech profile mode active');
      return;
    }

    // Only save if we're using custom STT and have transcripts
    final customSttConfig = SharedPreferencesUtil().customSttConfig;
    if (!customSttConfig.isEnabled) {
      debugPrint('[Finalize] SKIP: Custom STT not enabled');
      return;
    }

    if (segments.isEmpty) {
      debugPrint('[Finalize] SKIP: No segments to save');
      _clearRecoveryState();
      return;
    }

    // Prevent duplicate saves when stopStreamRecording() and forceProcessingCurrentConversation() both call this
    if (_conversationFinalized) {
      _captureLog.log('save', 'finalize_skipped_duplicate', severity: 'warning');
      debugPrint('[Finalize] SKIP: Already finalized (_conversationFinalized=true)');
      return;
    }
    _conversationFinalized = true;

    // Capture mutable state upfront — protects against concurrent _resetStateVariables()
    // which can wipe segments/draftId while we await OpenAI or network calls.
    final localSegments = List<TranscriptSegment>.from(segments);
    final localDraftId = _incrementalSave.draftId;

    final transcript = localSegments.map((s) => s.text).join('\n').trim();
    _captureLog.log('save', 'finalize_started', details: {
      'segments_count': localSegments.length,
      'has_draft': localDraftId != null,
      'transcript_length': transcript.length,
    });

    debugPrint('[Finalize] START: ${localSegments.length} segments, '
        'draftId=$localDraftId, '
        'transcript=${transcript.length} chars');

    // Cancel recovery timer but don't clear data yet (only after successful save)
    _recoveryTimer?.cancel();

    _finalizeInProgress = true;
    try {
      // Voice profile verification (non-blocking, outside retry loop)
      var userId = SupabaseAuthService.instance.maityUserId;
      if (userId == null) {
        debugPrint('[Finalize] userId null, attempting fetch...');
        userId = await SupabaseAuthService.instance.fetchMaityUserId();
      }
      debugPrint('[Finalize] userId=$userId');

      if (userId != null) {
        try {
          await _verifySpeakersWithVoiceProfile(userId);
          debugPrint('[Finalize] Voice profile verification completed');
        } catch (e) {
          debugPrint('[Finalize] Voice profile verification failed (non-blocking): $e');
          // Non-blocking: continue with finalize even if voice verification fails
        }
      }

      // Retry up to 3 times on failure
      const maxRetries = 3;
      int retryCount = 0;
      bool success = false;

      while (retryCount < maxRetries && !success) {
        try {
          // Check if we have a draft conversation (incremental save path)
          if (localDraftId != null && userId != null) {
            debugPrint('[Finalize] Incremental path: draft=$localDraftId');

            // Flush any pending segments first
            debugPrint('[Finalize] Flushing pending segments...');
            await _incrementalSave.flushPendingSegments(localSegments);
            debugPrint('[Finalize] Flush complete. Saved: ${_incrementalSave.savedSegmentCount}/${localSegments.length}');

            // Build transcript for local processing
            final transcript = localSegments.map((s) => s.text).join('\n').trim();

            // For long transcripts (>6000 chars), let backend handle processing
            Map<String, dynamic>? structuredData;
            if (transcript.length <= 6000) {
              // Process locally with OpenAI for short transcripts
              debugPrint('[Finalize] Processing locally (${transcript.length} chars)...');
              final structured = await ConversationProcessor.processLocally(localSegments);
              debugPrint('[Finalize] Local processing result: ${structured != null ? 'title="${structured.title}"' : 'null'}');
              if (structured != null) {
                structuredData = {
                  'title': structured.title,
                  'overview': structured.overview,
                  'emoji': structured.emoji,
                  'category': structured.category,
                  'discarded': structured.discarded,
                  'action_items': structured.actionItems.map((a) => a.toJson()).toList(),
                  'events': structured.events.map((e) => e.toJson()).toList(),
                };
              }
            } else {
              debugPrint('[Finalize] Long transcript (${transcript.length} chars), backend will process with chunking');
            }

            // Finalize via backend (rebuilds transcript from segments in DB)
            debugPrint('[Finalize] Calling incremental finalize (structured=${structuredData != null})...');
            final finalized = await _incrementalSave.finalize(
              userId: userId,
              finishedAt: DateTime.now(),
              structured: structuredData,
              draftId: localDraftId,
            );

            if (finalized) {
              _captureLog.log('save', 'finalize_incremental_success', details: {
                'draft_id': localDraftId,
              });
              debugPrint('[Finalize] SUCCESS via incremental path');

              // Notify conversation provider to refresh the list
              conversationProvider?.refreshConversations();

              _recordingStartTime = null;
              _clearRecoveryState();
              success = true;
            } else {
              _captureLog.log('save', 'finalize_incremental_failed', severity: 'warning', details: {
                'draft_id': localDraftId,
                'fallback': 'monolithic',
              });
              debugPrint('[Finalize] FAILED incremental path, falling back to monolithic');
              // Fall through to monolithic save below
            }
          }

          // Monolithic save (fallback or when no draft exists)
          if (!success) {
            if (_totalSegmentCount > localSegments.length) {
              debugPrint('[Finalize] WARNING: segments were trimmed '
                  '(have ${localSegments.length}/$_totalSegmentCount), '
                  'monolithic save will have partial transcript');
              _captureLog.log('save', 'monolithic_partial_transcript', severity: 'warning', details: {
                'available': localSegments.length,
                'total': _totalSegmentCount,
              });
            }
            debugPrint('[Finalize] Monolithic path: processing locally...');
            // Process conversation with OpenAI to get structured data (title, emoji, category, etc.)
            final structured = await ConversationProcessor.processLocally(localSegments);
            debugPrint('[Finalize] Monolithic processing result: ${structured != null ? 'title="${structured.title}"' : 'null'}');

            // Save the conversation locally with full structured data
            final conversation = await LocalConversationsService.saveConversation(
              segments: List.from(localSegments), // Copy segments
              startedAt: _recordingStartTime ?? DateTime.now(),
              structured: structured,
              // Fallback values if structured is null
              title: structured?.title ?? 'Conversación',
              emoji: structured?.emoji ?? '🎤',
              category: structured?.category ?? 'personal',
            );

            debugPrint('[Finalize] Monolithic save OK: id=${conversation.id}, title="${structured?.title}"');

            _captureLog.log('save', 'finalize_monolithic_success', details: {
              'conversation_id': conversation.id,
            });

            // Mark the orphan draft as abandoned so it doesn't linger as 'recording'
            if (localDraftId != null) {
              debugPrint('[Finalize] Marking orphan draft $localDraftId as abandoned...');
              try {
                await OmiSupabaseService.markDraftAbandoned(
                  conversationId: localDraftId,
                );
                debugPrint('[Finalize] Draft marked as abandoned');
              } catch (e) {
                debugPrint('[Finalize] Failed to mark draft as abandoned (non-blocking): $e');
              }
            }

            // Notify the conversation provider to add it to the list
            conversationProvider?.addLocalConversation(conversation);

            // Reset recording start time
            _recordingStartTime = null;

            // Clear recovery data only after successful save
            _clearRecoveryState();

            success = true;
          }
        } catch (e, stackTrace) {
          retryCount++;
          _captureLog.log('save', 'finalize_retry_error', severity: 'error', details: {
            'attempt': retryCount,
            'max_retries': maxRetries,
            'error': e.toString(),
          });
          debugPrint('[Finalize] ERROR attempt $retryCount/$maxRetries: $e');
          debugPrint('[Finalize] Stack trace: $stackTrace');

          if (retryCount < maxRetries) {
            // Wait before retrying (exponential backoff)
            final delay = Duration(seconds: retryCount * 2);
            debugPrint('[Finalize] Retrying in ${delay.inSeconds}s...');
            await Future.delayed(delay);
          } else {
            _captureLog.log('save', 'finalize_all_retries_exhausted', severity: 'error', details: {
              'segments_count': localSegments.length,
            });
            debugPrint('[Finalize] All retries exhausted. Recovery data preserved.');
            // Don't clear recovery data - keep it for later recovery
          }
        }
      }
    } finally {
      _finalizeInProgress = false;
    }
  }

  /// Verifies speakers using voice embeddings and re-labels is_user in segments.
  /// Uses the audio buffer stored during recording to extract audio for each speaker,
  /// then calls the voice profile service to verify against the user's voice profile.
  Future<void> _verifySpeakersWithVoiceProfile(String userId) async {
    // Check if user has voice profile
    final status = await VoiceProfileService.getProfileStatus(userId);
    if (!status.hasProfile) {
      debugPrint('[Maity] No voice profile found, using default speaker assignment');
      return;
    }

    debugPrint('[Maity] Voice profile found, created: ${status.createdAt}');

    // Check if we have audio buffer
    if (_audioBuffer == null || !_audioBuffer!.hasFrames()) {
      debugPrint('[Maity] No audio buffer available for speaker verification');
      return;
    }

    debugPrint('[Maity] Audio buffer has ${_audioBuffer!.durationSeconds.toStringAsFixed(1)}s of audio');

    // Get unique speaker IDs from segments
    final speakerIds = segments.map((s) => s.speakerId).toSet();
    debugPrint('[Maity] Found ${speakerIds.length} unique speakers: $speakerIds');

    // If only one speaker, skip verification (likely just the user)
    if (speakerIds.length <= 1) {
      debugPrint('[Maity] Only one speaker detected, skipping verification');
      return;
    }

    // Group segments by speaker
    final speakerSegments = <int, List<TranscriptSegment>>{};
    for (var seg in segments) {
      speakerSegments.putIfAbsent(seg.speakerId, () => []).add(seg);
    }

    // Extract audio for each speaker (use the longest segment for best accuracy)
    final speakerAudioSegments = <int, Uint8List>{};
    for (var entry in speakerSegments.entries) {
      // Find the longest segment for this speaker (better voice sample)
      final sortedSegments = List<TranscriptSegment>.from(entry.value)
        ..sort((a, b) => (b.end - b.start).compareTo(a.end - a.start));

      final longest = sortedSegments.first;
      final duration = longest.end - longest.start;

      // Skip if segment is too short (need at least 1 second for reliable verification)
      if (duration < 1.0) {
        debugPrint('[Maity] Speaker ${entry.key} segment too short (${duration.toStringAsFixed(1)}s), skipping');
        continue;
      }

      // Extract audio for this segment
      final audioBytes = _audioBuffer!.extractAudioRange(longest.start, longest.end);
      if (audioBytes != null) {
        speakerAudioSegments[entry.key] = audioBytes;
        debugPrint('[Maity] Extracted ${duration.toStringAsFixed(1)}s audio for speaker ${entry.key} (${audioBytes.length} bytes)');
      } else {
        debugPrint('[Maity] Failed to extract audio for speaker ${entry.key}');
      }
    }

    if (speakerAudioSegments.isEmpty) {
      debugPrint('[Maity] No valid speaker audio extracted, keeping default assignment');
      return;
    }

    // Call voice profile service to verify speakers
    try {
      debugPrint('[Maity] Calling voice profile verification for ${speakerAudioSegments.length} speakers');
      final results = await VoiceProfileService.verifySpeakers(
        userId: userId,
        speakerAudioSegments: speakerAudioSegments,
        threshold: 0.75,
      );

      debugPrint('[Maity] Verification results: $results');

      // Re-label segments based on verification results
      int updatedCount = 0;
      for (var seg in segments) {
        // Results are keyed by speaker ID as string (e.g., "0", "1")
        final result = results[seg.speakerId.toString()];
        if (result != null) {
          final wasUser = seg.isUser;
          seg.isUser = result.isUser;
          if (wasUser != seg.isUser) updatedCount++;
        }
      }

      debugPrint('[Maity] Updated is_user for $updatedCount segments based on voice verification');
    } catch (e) {
      debugPrint('[Maity] Speaker verification failed: $e');
      // Keep default assignment on error
    }
  }

  /// Resets the silence timer - called when new segments arrive
  /// Only active for custom STT mode
  void _resetSilenceTimer() {
    // Don't set up auto-save timer during speech profile training
    if (_isSpeechProfileMode) return;

    final customSttConfig = SharedPreferencesUtil().customSttConfig;
    if (!customSttConfig.isEnabled) return;

    _silenceTimer?.cancel();

    final timeoutSeconds = SharedPreferencesUtil().conversationSilenceDuration;
    if (timeoutSeconds <= 0) return; // -1 = manual only, no auto-save

    _silenceTimer = Timer(Duration(seconds: timeoutSeconds), () {
      _onSilenceTimeout();
    });
  }

  /// Called when silence timeout expires - auto-finalize conversation
  /// Distinguishes between real silence and STT stall (audio flowing but no segments)
  void _onSilenceTimeout() async {
    if (segments.isEmpty) return;

    // Check if audio is still actively being captured
    // If audio bytes are flowing but no segments → STT stall, not real silence
    if (_lastAudioBytesSentAt != null) {
      final audioGap = DateTime.now().difference(_lastAudioBytesSentAt!);
      if (audioGap.inSeconds < 10) {
        debugPrint('[Maity] Silence timeout but audio still flowing (${audioGap.inSeconds}s ago) - STT stall detected, attempting reconnection');
        _captureLog.log('recording', 'silence_timeout_stt_stall', details: {
          'audio_gap_seconds': audioGap.inSeconds,
          'segments_count': segments.length,
        });
        // Trigger STT reconnection instead of finalizing
        _onTranscriptionStalled();
        return;
      }
    }

    // Real silence - proceed with finalization
    _captureLog.log('recording', 'silence_timeout_triggered', details: {
      'timeout_seconds': SharedPreferencesUtil().conversationSilenceDuration,
      'segments_count': segments.length,
    });
    debugPrint('[Maity] Silence timeout (${SharedPreferencesUtil().conversationSilenceDuration}s) - auto-finalizing conversation');

    // Save recovery data as safety net before finalizing
    if (segments.isNotEmpty && _currentSessionId != null) {
      await TranscriptRecoveryService.saveSegments(
        sessionId: _currentSessionId!,
        startedAt: _recordingStartTime ?? DateTime.now(),
        segments: List.from(segments),
        draftConversationId: _incrementalSave.draftId,
      );
      debugPrint('[Maity] Recovery data saved before silence timeout finalize');
    }

    await _finalizeLocalConversation();
    if (!_finalizeInProgress) {
      _resetStateVariables();
    }
    notifyListeners();
  }

  /// Cancels the silence timer
  void _cancelSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// Schedules a recovery save with debouncing
  /// Saves every 5 seconds or after 5 new segments, whichever comes first.
  /// CRITICAL: Saves immediately on the first segment to prevent data loss on early crash.
  void _scheduleRecoverySave() {
    // Only save for custom STT mode
    final customSttConfig = SharedPreferencesUtil().customSttConfig;
    if (!customSttConfig.isEnabled) return;

    // Don't save during speech profile mode
    if (_isSpeechProfileMode) return;

    _unsavedSegmentCount++;

    // Save immediately on the FIRST segment — no debounce, so recovery exists from the start
    if (segments.length <= 1) {
      _saveRecoveryData();
      return;
    }

    // Save immediately if we have 5+ unsaved segments
    if (_unsavedSegmentCount >= 5) {
      _saveRecoveryData();
      return;
    }

    // Otherwise, debounce to every 5 seconds
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(const Duration(seconds: 5), _saveRecoveryData);
  }

  /// Saves current segments to recovery file
  Future<void> _saveRecoveryData({bool synchronous = false}) async {
    if (segments.isEmpty) return;

    try {
      // Ensure we have a session ID
      _currentSessionId ??= const Uuid().v4();

      final segmentsCopy = List<TranscriptSegment>.from(segments);

      if (synchronous) {
        // Synchronous path for app paused/detached (app may be killed)
        await TranscriptRecoveryService.saveSegments(
          sessionId: _currentSessionId!,
          startedAt: _recordingStartTime ?? DateTime.now(),
          segments: segmentsCopy,
          draftConversationId: _incrementalSave.draftId,
        );
      } else {
        // Async path: offload JSON encoding to background isolate
        await TranscriptRecoveryService.saveSegmentsAsync(
          sessionId: _currentSessionId!,
          startedAt: _recordingStartTime ?? DateTime.now(),
          segments: segmentsCopy,
          draftConversationId: _incrementalSave.draftId,
        );
      }

      _captureLog.log('recovery', 'recovery_data_saved', severity: 'debug', details: {
        'segments_count': segmentsCopy.length,
        'draft_id': _incrementalSave.draftId,
      });
      _unsavedSegmentCount = 0;
    } catch (e) {
      debugPrint('[CaptureProvider] Error saving recovery data: $e');
      _captureLog.log('recovery', 'recovery_save_failed', severity: 'error', details: {
        'error': e.toString(),
      });
    }
  }

  /// Clears recovery data and resets recovery state
  Future<void> _clearRecoveryState() async {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _unsavedSegmentCount = 0;
    _currentSessionId = null;
    try {
      await TranscriptRecoveryService.clearRecoveryData();
    } catch (e) {
      debugPrint('[CaptureProvider] Error clearing recovery state: $e');
    }
  }

  /// Schedules incremental save of segments to Supabase
  Future<void> _scheduleIncrementalSave() async {
    final customSttConfig = SharedPreferencesUtil().customSttConfig;
    if (!customSttConfig.isEnabled) return;
    if (_isSpeechProfileMode) return;

    var userId = SupabaseAuthService.instance.maityUserId;

    // Actively attempt to resolve userId if null
    if (userId == null) {
      debugPrint('[CaptureProvider] WARNING: maityUserId null during incremental save, attempting fetch...');
      userId = await SupabaseAuthService.instance.fetchMaityUserId();
    }

    if (userId == null) {
      debugPrint('[CaptureProvider] CRITICAL: Cannot save - maityUserId is null');
      _captureLog.log('save', 'skipped_no_user_id', severity: 'error');
      return;
    }

    // Ensure draft is created on first segment (await to prevent saving without draft)
    if (_incrementalSave.draftId == null && segments.isNotEmpty) {
      try {
        await _incrementalSave.ensureDraftCreated(
          userId: userId,
          startedAt: _recordingStartTime ?? DateTime.now(),
        );
      } catch (e) {
        _captureLog.log('save', 'draft_creation_failed', severity: 'error', details: {
          'error': e.toString(),
        });
        debugPrint('[CaptureProvider] Draft creation failed: $e');
        return;
      }
      if (_incrementalSave.draftId != null) {
        _captureLog.log('save', 'draft_created', details: {
          'draft_id': _incrementalSave.draftId,
        });
        _captureLog.updateConversationId(_incrementalSave.draftId!);
      } else {
        _captureLog.log('save', 'draft_creation_failed', severity: 'error', details: {
          'error': 'ensureDraftCreated returned null without throwing',
        });
        debugPrint('[CaptureProvider] Draft creation failed, skipping incremental save');
        return;
      }
    }

    // Save segments (debounced internally by IncrementalSaveService)
    _incrementalSave.saveNewSegments(segments);
  }

  /// Trims segments that have been confirmed saved to Supabase,
  /// keeping at most [_maxSegmentsInMemory] segments in memory.
  /// The finalize endpoint reconstructs the full transcript from Supabase.
  void _trimSavedSegments() {
    final savedCount = _incrementalSave.savedSegmentCount;
    if (savedCount <= 0 || segments.length <= _maxSegmentsInMemory) return;

    // Only trim saved segments, keeping at least _maxSegmentsInMemory
    final trimCount = (savedCount - _maxSegmentsInMemory).clamp(0, savedCount);
    if (trimCount <= 0) return;

    debugPrint('[CaptureProvider] Trimming $trimCount saved segments '
        '(total: ${segments.length}, saved: $savedCount, keeping: ${segments.length - trimCount})');

    segments.removeRange(0, trimCount);
    _incrementalSave.adjustAfterTrim(trimCount);
    _segmentsVersion++;

    _captureLog.log('memory', 'segments_trimmed', severity: 'debug', details: {
      'trimmed': trimCount,
      'remaining': segments.length,
      'total_produced': _totalSegmentCount,
    });
  }

  /// Starts the socket health monitor to detect stalled transcription
  void _startSocketHealthMonitor() {
    _socketHealthTimer?.cancel();
    _lastSegmentReceivedAt = null;

    _socketHealthTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkSocketHealth();
    });
  }

  /// Stops the socket health monitor
  void _stopSocketHealthMonitor() {
    _socketHealthTimer?.cancel();
    _socketHealthTimer = null;
    _lastSegmentReceivedAt = null;
  }

  /// Check if transcription has stalled
  void _checkSocketHealth() {
    try {
      // Only check when actively recording
      if (recordingState != RecordingState.record &&
          recordingState != RecordingState.deviceRecord &&
          recordingState != RecordingState.systemAudioRecord) {
        return;
      }

      // Only for custom STT mode
      final customSttConfig = SharedPreferencesUtil().customSttConfig;
      if (!customSttConfig.isEnabled) return;

      // Check if socket is disconnected
      if (_socket?.state != SocketServiceState.connected) {
        debugPrint('[Maity] Health monitor: socket disconnected during recording');
        return;
      }

      // Check if segments have stopped arriving (>60s gap)
      if (_lastSegmentReceivedAt != null && segments.isNotEmpty) {
        final gap = DateTime.now().difference(_lastSegmentReceivedAt!);
        if (gap.inSeconds > 60) {
          _captureLog.log('health', 'health_check_stall_detected', severity: 'warning', details: {
            'gap_seconds': gap.inSeconds,
            'socket_connected': _socket?.state == SocketServiceState.connected,
          });
          debugPrint('[Maity] Health monitor: no segments for ${gap.inSeconds}s');
          _onTranscriptionStalled();
        }
      }
    } catch (e) {
      debugPrint('[CaptureProvider] Health check error: $e');
    }
  }

  /// Called when transcription appears to have stalled (no segments for >60s)
  void _onTranscriptionStalled() async {
    // Only warn once until new segments arrive
    if (_lastSegmentReceivedAt == null) return;

    _captureLog.log('health', 'transcription_stalled', severity: 'error', details: {
      'total_segments': segments.length,
      'reconnect_attempt': _sttReconnectAttempts,
    });

    // Clear timestamp to avoid repeated triggers while reconnecting
    _lastSegmentReceivedAt = null;

    _sttReconnectAttempts++;
    if (_sttReconnectAttempts > _maxSttReconnectAttempts) {
      debugPrint('[Maity] Max STT reconnect attempts reached ($_maxSttReconnectAttempts) - notifying user and auto-finalizing');
      _showStallNotification();
      // Auto-finalize conversation instead of leaving it in zombie state
      _autoFinalizeOnConnectionLost();
      return;
    }

    debugPrint('[Maity] Transcription stalled - STT reconnect attempt $_sttReconnectAttempts/$_maxSttReconnectAttempts');

    // Kill current socket and create new one
    await _socket?.stop(reason: 'transcription stalled');

    if (recordingState == RecordingState.record) {
      await _initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.phone.name,
      );
    } else if (recordingState == RecordingState.deviceRecord && _recordingDevice != null) {
      BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
      await _initiateWebsocket(audioCodec: codec, force: true, source: _getConversationSourceFromDevice());
    } else if (recordingState == RecordingState.systemAudioRecord) {
      await _initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.desktop.name,
      );
    }

    // Reset silence timer to give new socket time to produce segments
    _resetSilenceTimer();

    // Set timestamp so health monitor can detect if reconnected socket also stalls
    _lastSegmentReceivedAt = DateTime.now();
  }

  /// Shows a notification when transcription has stalled and reconnection failed
  void _showStallNotification() {
    final lang = SharedPreferencesUtil().appLanguage;
    final title = lang == 'es' ? 'Transcripción interrumpida' : 'Transcription Lost';
    final body = lang == 'es'
        ? 'No se han recibido segmentos de transcripción en más de 60 segundos.'
        : 'No transcription segments received for over 60 seconds.';

    NotificationService.instance.createNotification(
      title: title,
      body: body,
      notificationId: 3,
    );
  }

  /// Auto-finalizes the current conversation when connection is permanently lost.
  /// Called when keep-alive or STT reconnect attempts are exhausted.
  /// Saves whatever segments we have and cleanly stops recording.
  Future<void> _autoFinalizeOnConnectionLost() async {
    if (segments.isEmpty || _conversationFinalized) return;

    _captureLog.log('recording', 'auto_finalize_connection_lost', severity: 'warning', details: {
      'segments_count': segments.length,
      'keep_alive_attempts': _keepAliveAttempts,
      'stt_reconnect_attempts': _sttReconnectAttempts,
      'has_draft': _incrementalSave.draftId != null,
    });

    debugPrint('[Maity] Auto-finalizing conversation due to connection loss (${segments.length} segments)');

    // Save recovery data as backup in case finalization fails
    if (_currentSessionId != null) {
      await TranscriptRecoveryService.saveSegments(
        sessionId: _currentSessionId!,
        startedAt: _recordingStartTime ?? DateTime.now(),
        segments: List.from(segments),
        draftConversationId: _incrementalSave.draftId,
      );
    }

    // Stop socket and microphone
    await _socket?.stop(reason: 'connection lost - auto finalizing');
    ServiceManager.instance().mic.stop();
    CaptureProvider.isRecordingWithPhoneMic = false;
    _stopSocketHealthMonitor();
    _cancelSilenceTimer();

    // Finalize with whatever segments we have
    await _finalizeLocalConversation();
    await _resetStateVariables();
    updateRecordingState(RecordingState.stop);
    _captureLog.endSession();
    notifyListeners();
  }

  /// Recovers an interrupted session from the recovery file
  /// Returns true if recovery was successful
  Future<bool> recoverInterruptedSession(
    List<TranscriptSegment> recoverySegments,
    DateTime startedAt, {
    String? draftConversationId,
  }) async {
    if (recoverySegments.isEmpty) {
      debugPrint('[Maity] No segments to recover');
      await TranscriptRecoveryService.clearRecoveryData();
      return false;
    }

    _captureLog.log('recovery', 'recovery_attempted', details: {
      'segments_count': recoverySegments.length,
      'draft_id': draftConversationId,
    });
    debugPrint('[Maity] Recovering session with ${recoverySegments.length} segments (draft: $draftConversationId)');

    try {
      // Get user ID
      final userId = SupabaseAuthService.instance.maityUserId;
      if (userId == null) {
        debugPrint('[Maity] No user ID, cannot recover');
        return false;
      }

      // If we have a draft conversation, finalize it via backend
      if (draftConversationId != null) {
        debugPrint('[Maity] Finalizing draft $draftConversationId from recovery');

        final transcript = recoverySegments.map((s) => s.text).join('\n').trim();

        // Build structured data for short transcripts
        Map<String, dynamic>? structuredData;
        if (transcript.length <= 6000) {
          final structured = await ConversationProcessor.processLocally(recoverySegments);
          if (structured != null) {
            structuredData = {
              'title': structured.title,
              'overview': structured.overview,
              'emoji': structured.emoji,
              'category': structured.category,
              'discarded': structured.discarded,
              'action_items': structured.actionItems.map((a) => a.toJson()).toList(),
              'events': structured.events.map((e) => e.toJson()).toList(),
            };
          }
        }

        final finalized = await OmiSupabaseService.finalizeConversation(
          conversationId: draftConversationId,
          userId: userId,
          finishedAt: DateTime.now(),
          structured: structuredData,
        );

        if (finalized) {
          debugPrint('[Maity] Draft finalized from recovery');
          conversationProvider?.refreshConversations();
          await TranscriptRecoveryService.clearRecoveryData();
          return true;
        }

        debugPrint('[Maity] Draft finalize failed, falling back to monolithic save');
      }

      // Fallback: monolithic save
      final structured = await ConversationProcessor.processLocally(recoverySegments);

      final conversation = await LocalConversationsService.saveConversation(
        segments: List.from(recoverySegments),
        startedAt: startedAt,
        structured: structured,
        title: structured?.title ?? 'Recovered Conversation',
        emoji: structured?.emoji ?? '🔄',
        category: structured?.category ?? 'personal',
      );

      debugPrint('[Maity] Recovered conversation saved: ${conversation.id}');

      _captureLog.log('recovery', 'recovery_succeeded', details: {
        'conversation_id': conversation.id,
        'segments_count': recoverySegments.length,
      });

      // Notify the conversation provider to add it to the list
      conversationProvider?.addLocalConversation(conversation);

      // Clear recovery data after successful save
      await TranscriptRecoveryService.clearRecoveryData();

      return true;
    } catch (e) {
      _captureLog.log('recovery', 'recovery_failed', severity: 'error', details: {
        'error': e.toString(),
      });
      debugPrint('[Maity] Error recovering session: $e');
      return false;
    }
  }

  Future<void> pauseDeviceRecording() async {
    if (_recordingDevice == null) return;

    _captureLog.log('recording', 'recording_paused', details: {'source': 'ble_device'});
    // Pause the BLE stream but keep the device connection
    await _bleBytesStream?.cancel();
    _isPaused = true;
    updateRecordingState(RecordingState.pause);
    notifyListeners();
  }

  Future<void> resumeDeviceRecording() async {
    if (_recordingDevice == null) return;
    _captureLog.log('recording', 'recording_resumed', details: {'source': 'ble_device'});
    _isPaused = false;
    // Resume streaming from the device
    await _initiateDeviceAudioStreaming();

    final deviceId = _recordingDevice!.id;
    BleAudioCodec codec = await _getAudioCodec(deviceId);
    await _wal.getSyncs().phone.onAudioCodecChanged(codec);

    await streamAudioToWs(deviceId, codec);

    updateRecordingState(RecordingState.deviceRecord);
    notifyListeners();
  }
}
