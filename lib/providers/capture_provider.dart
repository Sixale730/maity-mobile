import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/person.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/providers/people_provider.dart';
import 'package:omi/providers/local_stt_provider.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart';
import 'package:omi/services/vad/vad_state.dart';
import 'package:omi/services/vad/vad_metrics.dart';
import 'package:omi/services/widget_state_service.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/platform/platform_service.dart';

// Decomposed services
import 'package:omi/services/recording/recording_state_machine.dart';
import 'package:omi/services/recording/audio_transport_service.dart';
import 'package:omi/services/recording/transcription_pipeline.dart';
import 'package:omi/services/recording/persistence_manager.dart';
import 'package:omi/services/recording/app_lifecycle_manager.dart';
import 'package:omi/services/recording/session_lifecycle_manager.dart';
import 'package:omi/services/recording/recording_controller.dart';
import 'package:omi/services/recording/message_event_handler.dart';
import 'package:omi/services/recording/telemetry_collector.dart';
import 'package:omi/services/devices/led_breathing_service.dart';
import 'package:omi/services/devices.dart';

/// Slim coordinator that delegates to focused services.
///
/// Services:
/// - [RecordingStateMachine]   — FSM with validated state transitions
/// - [AudioTransportService]   — Phone mic, BLE, system audio routing
/// - [TranscriptionPipeline]   — Socket lifecycle, segment buffering, health monitor
/// - [PersistenceManager]      — Save, recovery, finalize with Mutex
/// - [AppLifecycleManager]     — Background/foreground handling
/// - [RecordingController]     — Start/stop/pause/resume/cancel orchestration
class CaptureProvider extends ChangeNotifier
    with MessageNotifierMixin
    implements AppLifecycleDelegate {
  /// Backward-compat static flag used by DeviceProvider to skip BLE reconnection.
  static bool isRecordingWithPhoneMic = false;

  ConversationProvider? conversationProvider;
  MessageProvider? messageProvider;
  PeopleProvider? peopleProvider;
  UsageProvider? usageProvider;

  /// Wire the [LocalSttProvider] for engine warm-up. Call from HomePage
  /// once (it's safe to call multiple times; only the latest reference
  /// is kept).
  void setLocalSttProvider(LocalSttProvider provider) {
    _pipeline.warmEngineProvider = provider.acquireEngine;
    _pipeline.onLocalEngineReleased = provider.releaseEngine;
  }

  // ---------------------------------------------------------------------------
  // Services
  // ---------------------------------------------------------------------------

  final RecordingStateMachine _stateMachine = RecordingStateMachine();
  final AudioTransportService _audioTransport = AudioTransportService();
  final TranscriptionPipeline _pipeline = TranscriptionPipeline();
  final PersistenceManager _persistence = PersistenceManager();
  final AppLifecycleManager _lifecycle = AppLifecycleManager();
  final SessionLifecycleManager _sessionLifecycle = SessionLifecycleManager();
  final LedBreathingService _ledBreathing = LedBreathingService();

  late final RecordingController _recordingController;
  final MessageEventHandler _messageEventHandler = MessageEventHandler();

  // ---------------------------------------------------------------------------
  // Connection state
  // ---------------------------------------------------------------------------

  StreamSubscription<bool>? _connectionStateListener;
  bool _isConnected = ConnectivityService().isConnected;
  get isConnected => _isConnected;

  bool _isWalSupported = false;
  bool get isWalSupported => _isWalSupported;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  CaptureProvider() {
    // Build recording controller with all service dependencies
    _recordingController = RecordingController(
      stateMachine: _stateMachine,
      audioTransport: _audioTransport,
      pipeline: _pipeline,
      persistence: _persistence,
      sessionLifecycle: _sessionLifecycle,
    );

    // Wire controller callbacks
    _recordingController.onRecordingStateChanged = updateRecordingState;
    _recordingController.onNotifyListeners = notifyListeners;
    _recordingController.onConversationFinalized = () {
      conversationProvider?.refreshConversations();
    };
    _recordingController.onAutoRestartNeeded = _autoRestartIfDeviceConnected;

    // Wire message event handler callbacks
    _messageEventHandler.onConversationUpserted = (conversation) {
      conversationProvider?.upsertConversation(conversation);
    };
    _messageEventHandler.onProcessingStarted = (memory) {
      conversationProvider?.addProcessingConversation(memory);
    };
    _messageEventHandler.onProcessingConversationRemoved = (id) {
      conversationProvider?.removeProcessingConversation(id);
    };
    _messageEventHandler.onResetStateVariables = () {
      // Guard: only reset if no recording is active. Prevents
      // ConversationProcessingStartedEvent for a prior conversation from
      // destroying the current session.
      if (_stateMachine.isIdle) {
        _resetStateVariables();
      } else {
        debugPrint('[CaptureProvider] Ignoring onResetStateVariables from '
            'MessageEventHandler — recording is active '
            '(state=${_stateMachine.state.name})');
      }
    };
    _messageEventHandler.onNotifyListeners = notifyListeners;
    _messageEventHandler.getSegments = () => segments;
    _messageEventHandler.getPhotos = () => photos;
    _messageEventHandler.getTaggingSegmentIds = () => taggingSegmentIds;
    _messageEventHandler.onSpeakerAssignment =
        (speakerId, personId, personName, segmentIds) {
      assignSpeakerToConversation(
          speakerId, personId, personName, segmentIds);
    };
    _messageEventHandler.onSpeakerSuggestion = (event) {
      suggestionsBySegmentId[event.segmentId] = event;
      notifyListeners();
    };

    _connectionStateListener =
        ConnectivityService().onConnectionChange.listen((bool connected) {
      _isConnected = connected;
      _pipeline.onConnectionStateChanged(connected);
      notifyListeners();
    });

    // Wire up pipeline callbacks
    _pipeline.onSegmentsReceived = _onNewSegments;
    _pipeline.onMessageEvent = _messageEventHandler.handleEvent;
    _pipeline.onAutoFinalizeNeeded = _recordingController.autoFinalizeOnConnectionLost;
    _pipeline.onNotifyListeners = notifyListeners;
    _pipeline.onSchedulePostFrame = (callback) {
      WidgetsBinding.instance.addPostFrameCallback((_) => callback());
    };
    _pipeline.onSilenceTimeout = _recordingController.onSilenceTimeout;
    _pipeline.onTranscriptionStalled = _recordingController.reconnectForStall;

    // Wire up audio transport
    _audioTransport.setNotifyListenersCallback(notifyListeners);

    // Initialize lifecycle manager (registers WidgetsBindingObserver)
    if (PlatformService.isDesktop) {
      _lifecycle.initialize(
        delegate: this,
        screenCaptureChannel: const MethodChannel('screenCapturePlatform'),
        controlBarChannel: const MethodChannel('com.omi/floating_control_bar'),
      );
    } else {
      _lifecycle.initialize(delegate: this);
    }

    // Initialize audio transport (desktop method channels)
    _audioTransport.initialize();
  }

  // ---------------------------------------------------------------------------
  // Provider dependency injection
  // ---------------------------------------------------------------------------

  void updateProviderInstances(ConversationProvider? cp, MessageProvider? mp,
      PeopleProvider? pp, UsageProvider? up) {
    conversationProvider = cp;
    messageProvider = mp;
    peopleProvider = pp;
    usageProvider = up;

    conversationProvider?.refreshConversations();

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Public API — State getters (backwards-compat with UI)
  // ---------------------------------------------------------------------------

  @override
  RecordingState get recordingState => _stateMachine.state;
  @override
  bool get isPaused => _stateMachine.isPaused;
  @override
  bool get shouldAutoResumeAfterWake => _stateMachine.shouldAutoResumeAfterWake;

  List<TranscriptSegment> get segments => _pipeline.displaySegments;
  set segments(List<TranscriptSegment> value) => _pipeline.segments = value;

  int get segmentsVersion => _pipeline.segmentsVersion;
  bool get hasTranscripts => _pipeline.hasTranscripts;
  set hasTranscripts(bool value) => _pipeline.setHasTranscripts(value);

  /// Whether the chunk pipeline has audio that hasn't produced segments yet.
  bool get hasUnprocessedAudio => _pipeline.hasUnprocessedAudio;

  /// VAD activity indicator from local STT worker (replaces preview text).
  ValueNotifier<bool> get vadSpeechActive => _pipeline.vadSpeechActive;

  List<ConversationPhoto> get photos => _audioTransport.photos;

  List<MessageEvent> get transcriptionServiceStatuses =>
      _pipeline.transcriptionServiceStatuses;
  bool get transcriptServiceReady => _pipeline.transcriptServiceReady;

  SttProvider? get activeSttProvider => _pipeline.activeSttProvider;

  @override
  BtDevice? get recordingDevice => _audioTransport.recordingDevice;
  bool get havingRecordingDevice => _audioTransport.recordingDevice != null;

  bool get recordingDeviceServiceReady =>
      _audioTransport.recordingDevice != null ||
      recordingState == RecordingState.record ||
      recordingState == RecordingState.systemAudioRecord;

  // BLE metrics
  double get bleReceiveRateKbps => _audioTransport.bleReceiveRateKbps;
  double get wsSendRateKbps => _audioTransport.wsSendRateKbps;

  // Desktop audio
  String? get microphoneName => _audioTransport.microphoneName;
  double get microphoneLevel => _audioTransport.microphoneLevel;
  double get systemAudioLevel => _audioTransport.systemAudioLevel;

  // Auto-reconnect (desktop)
  bool get isAutoReconnecting => _audioTransport.isAutoReconnecting;
  int get reconnectCountdown => _audioTransport.reconnectCountdown;

  // Reconnecting socket
  bool get isReconnectingSocket => _lifecycle.isReconnectingSocket;

  // VAD
  VadMetrics? get vadMetrics => _pipeline.vadMetrics;
  bool get isVadActive => _pipeline.isVadActive;
  ValueNotifier<VadState?> get vadStateNotifier => _pipeline.vadStateNotifier;

  bool get outOfCredits => usageProvider?.isOutOfCredits ?? false;

  // Speaker label suggestions
  Map<String, SpeakerLabelSuggestionEvent> suggestionsBySegmentId = {};
  List<String> taggingSegmentIds = [];

  // Auto-save message (exposed from controller)
  ValueNotifier<String?> get autoSaveMessage =>
      _recordingController.autoSaveMessage;

  // ---------------------------------------------------------------------------
  // Public API — Recording controls (delegate to RecordingController)
  // ---------------------------------------------------------------------------

  @override
  void updateRecordingState(RecordingState state) {
    // Stop LED breathing whenever leaving pause state
    if (state != RecordingState.pause && _ledBreathing.isActive) {
      _stopBreathingLed();
    }
    _stateMachine.transition(state);
    CaptureProvider.isRecordingWithPhoneMic =
        _stateMachine.isRecordingWithPhoneMic;
    notifyListeners();
    _lifecycle.broadcastRecordingState();
    _lifecycle.updateForegroundNotification(_getNotificationState());
    _syncWidgetState();

    // Signal recording controller's ready completer
    _recordingController.signalRecordingReady(state);
  }

  void _syncWidgetState() {
    WidgetStateService.syncState(
      isRecording: _stateMachine.isRecording,
      isPaused: _stateMachine.isPaused,
      segmentCount: segments.length,
    );
  }

  void updateRecordingDevice(BtDevice? device) {
    _audioTransport.updateRecordingDevice(device);
    _lifecycle.updateForegroundNotification(_getNotificationState());
  }

  void setHasTranscripts(bool value) {
    _pipeline.setHasTranscripts(value);
    notifyListeners();
  }

  void setIsWalSupported(bool value) {
    _isWalSupported = value;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Recording controls — thin delegates to RecordingController
  // ---------------------------------------------------------------------------

  Future<void> streamRecording() => _recordingController.streamRecording();

  Future<void> stopStreamRecording() =>
      _recordingController.stopStreamRecording();

  Future<void> streamDeviceRecording({BtDevice? device}) =>
      _recordingController.streamDeviceRecording(device: device);

  Future<void> stopStreamDeviceRecording({bool cleanDevice = false}) =>
      _recordingController.stopStreamDeviceRecording(
          cleanDevice: cleanDevice);

  Future<void> pauseDeviceRecording() async {
    await _recordingController.pauseDeviceRecording();
    _startBreathingLed();
  }

  Future<void> resumeDeviceRecording() =>
      _recordingController.resumeDeviceRecording();

  Future<void> pausePhoneMicRecording() =>
      _recordingController.pausePhoneMicRecording();

  Future<void> resumePhoneMicRecording() =>
      _recordingController.resumePhoneMicRecording();

  @override
  Future<void> streamSystemAudioRecording() async {
    if (!PlatformService.isDesktop) {
      notifyError(
          'System audio recording is only available on macOS and Windows.');
      return;
    }
    await _recordingController.streamSystemAudioRecording();
  }

  Future<void> stopSystemAudioRecording() =>
      _recordingController.stopSystemAudioRecording();

  Future<void> pauseSystemAudioRecording({bool isAuto = false}) =>
      _recordingController.pauseSystemAudioRecording(isAuto: isAuto);

  Future<void> resumeSystemAudioRecording() =>
      _recordingController.resumeSystemAudioRecording();

  Future<void> cancelRecording() => _recordingController.cancelRecording();

  Future<void> forceProcessingCurrentConversation() =>
      _recordingController.forceProcessingCurrentConversation();

  // ---------------------------------------------------------------------------
  // Speech profile mode
  // ---------------------------------------------------------------------------

  void enterSpeechProfileMode() {
    _stateMachine.enterSpeechProfileMode();
    _pipeline.cancelSilenceTimer();
  }

  void exitSpeechProfileMode() {
    _stateMachine.exitSpeechProfileMode();
    _pipeline.clearSegments();
    _resetStateVariables();
  }

  void clearTranscripts() {
    _pipeline.clearSegments();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Transcription settings changes (delegate to controller)
  // ---------------------------------------------------------------------------

  Future<void> onRecordProfileSettingChanged() =>
      _recordingController.onRecordProfileSettingChanged();

  Future<void> onTranscriptionSettingsChanged() =>
      _recordingController.onTranscriptionSettingsChanged();

  Future<void> onVadSettingsChanged() async {
    if (recordingState == RecordingState.record ||
        recordingState == RecordingState.systemAudioRecord) {
      final customSttConfig = SharedPreferencesUtil().customSttConfig;
      final effectiveConfig =
          customSttConfig.isEnabled ? customSttConfig : null;
      await _pipeline.initializeVadService(
          BleAudioCodec.pcm16, effectiveConfig);
      notifyListeners();
    }
  }

  Future<void> changeAudioRecordProfile({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    String? source,
  }) =>
      _recordingController.changeAudioRecordProfile(
        audioCodec: audioCodec,
        sampleRate: sampleRate,
        channels: channels,
        isPcm: isPcm,
        source: source,
      );

  // ---------------------------------------------------------------------------
  // Recovery
  // ---------------------------------------------------------------------------

  Future<bool> recoverInterruptedSession(
    List<TranscriptSegment> recoverySegments,
    DateTime startedAt, {
    String? draftConversationId,
  }) async {
    return _persistence.recoverInterruptedSession(
      recoverySegments,
      startedAt,
      draftConversationId: draftConversationId,
      onConversationSaved: (conversation) {
        conversationProvider?.addLocalConversation(conversation);
      },
      onConversationsRefreshed: () {
        conversationProvider?.refreshConversations();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Speaker assignment
  // ---------------------------------------------------------------------------

  Future<void> assignSpeakerToConversation(
      int speakerId, String personId, String personName,
      List<String> segmentIds) async {
    if (segmentIds.isEmpty) return;

    taggingSegmentIds = List.from(segmentIds);
    notifyListeners();

    try {
      String finalPersonId = personId;
      if (finalPersonId.isEmpty) {
        Person? newPerson =
            await peopleProvider?.createPersonProvider(personName);
        if (newPerson != null) finalPersonId = newPerson.id;
      }

      final isAssigningToUser = finalPersonId == 'user';
      for (var segment in segments) {
        if (segmentIds.contains(segment.id)) {
          segment.isUser = isAssigningToUser;
          segment.personId = isAssigningToUser ? null : finalPersonId;
        }
      }

      if (_pipeline.socket?.state == SocketServiceState.connected) {
        _pipeline.sendToSocket(jsonEncode({
          'type': 'speaker_assigned',
          'speaker_id': speakerId,
          'person_id': finalPersonId,
          'person_name': personName,
          'segment_ids': segmentIds,
        }));
      }

      suggestionsBySegmentId
          .removeWhere((key, value) => value.speakerId == speakerId);
    } finally {
      taggingSegmentIds = [];
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // AppLifecycleDelegate implementation
  // ---------------------------------------------------------------------------

  @override
  bool get conversationFinalized => _stateMachine.conversationFinalized;
  @override
  List<TranscriptSegment> get currentSegments => segments;
  @override
  bool get isSpeechProfileMode => _stateMachine.isSpeechProfileMode;
  @override
  SocketServiceState? get socketState => _pipeline.socket?.state;
  @override
  int get recordingDuration => _audioTransport.recordingDuration;

  @override
  Future<void> stopHealthMonitor() async => _pipeline.stopHealthMonitor();
  @override
  void cancelKeepAlive() => _pipeline.stopKeepAlive();
  @override
  void cancelSilenceTimer() => _pipeline.cancelSilenceTimer();
  @override
  void resetSilenceTimer() => _pipeline.resetSilenceTimer();
  @override
  void startMetricsTracking() => _audioTransport.startMetricsTracking();
  @override
  Future<void> startHealthMonitor() async => _pipeline.startHealthMonitor();
  @override
  Future<void> reconnectSocket() async =>
      _recordingController.reconnectForStall();
  @override
  void startKeepAlive() => _pipeline.startKeepAlive();
  @override
  Future<void> saveRecoveryData({bool synchronous = false}) async {
    if (segments.isNotEmpty && _stateMachine.currentSessionId != null) {
      await _persistence.saveRecoveryData(
        segments,
        _stateMachine.currentSessionId!,
        _stateMachine.recordingStartTime ?? DateTime.now(),
        synchronous: synchronous,
      );
    }
  }

  @override
  Future<void> stopMicService() async {
    try {
      ServiceManager.instance().mic.stop();
    } catch (e) {
      debugPrint('[CaptureProvider] Error stopping mic service: $e');
    }
  }

  @override
  Future<void> stopMicServiceCompletely() async {
    try {
      ServiceManager.instance().mic.stopService();
    } catch (e) {
      debugPrint('[CaptureProvider] Error stopping mic service completely: $e');
    }
  }

  @override
  Future<void> stopSocket(String reason) async =>
      _pipeline.stopSocket(reason);
  @override
  Future<void> autoFinalizeOnConnectionLost() async =>
      _recordingController.autoFinalizeOnConnectionLost();
  @override
  void notifyListenersCallback() => notifyListeners();

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  String _getNotificationState() {
    if (recordingState == RecordingState.record ||
        (recordingState == RecordingState.deviceRecord &&
            _audioTransport.recordingDevice != null) ||
        recordingState == RecordingState.systemAudioRecord) {
      return 'recording';
    }
    if (recordingState == RecordingState.initialising ||
        recordingState == RecordingState.processing) {
      return 'processing';
    }
    if (_audioTransport.recordingDevice != null) return 'device_connected';
    return 'waiting';
  }

  void _resetStateVariables() {
    _pipeline.clearSegments();
    _audioTransport.photos.clear();
    suggestionsBySegmentId = {};
    taggingSegmentIds = [];
    _stateMachine.endSession();
    CaptureProvider.isRecordingWithPhoneMic = false;
    _persistence.reset();
    if (_sessionLifecycle.phase != SessionPhase.idle) {
      _sessionLifecycle.reset();
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Callbacks from TranscriptionPipeline
  // ---------------------------------------------------------------------------

  void _onNewSegments(List<TranscriptSegment> newSegments) {
    final wordCount = segments.fold<int>(
        0,
        (sum, s) =>
            sum +
            s.text
                .split(RegExp(r'\s+'))
                .where((w) => w.isNotEmpty)
                .length);
    TelemetryCollector.instance.updateSegmentMetrics(
      segmentsCount: segments.length,
      wordsCount: wordCount,
    );
    final activeProvider = _pipeline.activeSttProvider;
    if (activeProvider != null) {
      TelemetryCollector.instance.setSttProvider(activeProvider.name);
    }

    _persistence.scheduleLocalSave(
      segments,
      _stateMachine.currentSessionId,
      _stateMachine.recordingStartTime,
      _stateMachine.isSpeechProfileMode,
    );
  }

  // ---------------------------------------------------------------------------
  // Auto-restart after finalize
  // ---------------------------------------------------------------------------

  /// Auto-restart recording when an OMI device is still connected.
  void _autoRestartIfDeviceConnected(bool wasPaused) {
    final device = _audioTransport.recordingDevice;
    if (device == null) {
      _sessionLifecycle.transition(SessionPhase.idle);
      return;
    }

    debugPrint(
        '[CaptureProvider] Auto-restart: device ${device.name} still connected'
        '${wasPaused ? ' (will pause)' : ''}');

    // Transition to restarting phase (prevents concurrent restarts)
    if (!_sessionLifecycle.transition(SessionPhase.restarting)) {
      debugPrint(
          '[CaptureProvider] Auto-restart blocked: phase=${_sessionLifecycle.phase}');
      return;
    }

    // Brief settle delay
    Future.delayed(const Duration(milliseconds: 500), () async {
      // Guard: still in restarting phase and device still available
      if (_sessionLifecycle.phase != SessionPhase.restarting) return;
      if (_audioTransport.recordingDevice == null) {
        _sessionLifecycle.transition(SessionPhase.idle);
        return;
      }

      try {
        await streamDeviceRecording(device: device);

        if (wasPaused && recordingState == RecordingState.deviceRecord) {
          debugPrint('[CaptureProvider] Auto-pausing restarted recording');
          await pauseDeviceRecording();
        }
      } catch (e) {
        debugPrint('[CaptureProvider] Auto-restart failed: $e');
        _sessionLifecycle.transition(SessionPhase.idle);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // LED Breathing (visual pause indicator)
  // ---------------------------------------------------------------------------

  Future<void> _startBreathingLed() async {
    final device = _audioTransport.recordingDevice;
    if (device == null) return;
    try {
      final connection =
          await ServiceManager.instance().device.ensureConnection(device.id);
      if (connection == null) return;
      final features = await connection.getFeatures();
      if ((features & OmiFeatures.ledDimming) == 0) return;
      await _ledBreathing.start(connection);
    } catch (e) {
      debugPrint('[CaptureProvider] Failed to start LED breathing: $e');
    }
  }

  Future<void> _stopBreathingLed() async {
    if (!_ledBreathing.isActive) return;
    try {
      await _ledBreathing.stop();
    } catch (_) {
      _ledBreathing.cancel();
    }
  }

  @override
  void stopBreathingLed() => _stopBreathingLed();

  @override
  void startBreathingLedIfPaused() {
    if (_stateMachine.state == RecordingState.pause &&
        _audioTransport.recordingDevice != null) {
      _startBreathingLed();
    }
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    debugPrint('[CaptureProvider] dispose() called');
    _connectionStateListener?.cancel();
    _recordingController.dispose();
    _audioTransport.dispose();
    _pipeline.dispose();
    _persistence.dispose();
    _lifecycle.dispose();
    _stateMachine.dispose();
    _sessionLifecycle.dispose();
    _ledBreathing.dispose();
    super.dispose();
  }
}
