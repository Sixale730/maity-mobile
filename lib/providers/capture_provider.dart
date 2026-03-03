import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/sockets/transcription_service.dart';
import 'package:uuid/uuid.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/services/vad/vad_state.dart';
import 'package:omi/services/vad/vad_metrics.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/platform/platform_service.dart';

// New decomposed services
import 'package:omi/services/recording/recording_state_machine.dart';
import 'package:omi/services/recording/audio_transport_service.dart';
import 'package:omi/services/recording/transcription_pipeline.dart';
import 'package:omi/services/recording/persistence_manager.dart';
import 'package:omi/services/recording/app_lifecycle_manager.dart';

/// Slim coordinator that delegates to 5 focused services.
///
/// Services:
/// - [RecordingStateMachine] — FSM with validated state transitions
/// - [AudioTransportService]  — Phone mic, BLE, system audio routing
/// - [TranscriptionPipeline]  — Socket lifecycle, segment buffering, health monitor
/// - [PersistenceManager]     — Save, recovery, finalize with Mutex
/// - [AppLifecycleManager]    — Background/foreground handling
class CaptureProvider extends ChangeNotifier
    with MessageNotifierMixin
    implements AppLifecycleDelegate {
  /// Backward-compat static flag used by DeviceProvider to skip BLE reconnection.
  static bool isRecordingWithPhoneMic = false;

  ConversationProvider? conversationProvider;
  MessageProvider? messageProvider;
  PeopleProvider? peopleProvider;
  UsageProvider? usageProvider;

  // ---------------------------------------------------------------------------
  // Services
  // ---------------------------------------------------------------------------

  final RecordingStateMachine _stateMachine = RecordingStateMachine();
  final AudioTransportService _audioTransport = AudioTransportService();
  final TranscriptionPipeline _pipeline = TranscriptionPipeline();
  final PersistenceManager _persistence = PersistenceManager();
  final AppLifecycleManager _lifecycle = AppLifecycleManager();

  // ---------------------------------------------------------------------------
  // Connection state
  // ---------------------------------------------------------------------------

  StreamSubscription<bool>? _connectionStateListener;
  bool _isConnected = ConnectivityService().isConnected;
  get isConnected => _isConnected;

  bool _isWalSupported = false;
  bool get isWalSupported => _isWalSupported;

  CaptureLogService get _captureLog => CaptureLogService.instance;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  CaptureProvider() {
    _connectionStateListener =
        ConnectivityService().onConnectionChange.listen((bool connected) {
      _isConnected = connected;
      _pipeline.onConnectionStateChanged(connected);
      notifyListeners();
    });

    // Wire up pipeline callbacks
    _pipeline.onSegmentsReceived = _onNewSegments;
    _pipeline.onMessageEvent = _onMessageEvent;
    _pipeline.onAutoFinalizeNeeded = _autoFinalizeOnConnectionLost;
    _pipeline.onNotifyListeners = notifyListeners;
    _pipeline.onSilenceTimeout = _onSilenceTimeout;
    _pipeline.onTranscriptionStalled = _reconnectForStall;

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

    // Clean up orphan drafts (fire-and-forget)
    _persistence.cleanupOrphanDrafts(SupabaseAuthService.instance.maityUserId);
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

  List<TranscriptSegment> get segments => _pipeline.segments;
  set segments(List<TranscriptSegment> value) => _pipeline.segments = value;

  int get segmentsVersion => _pipeline.segmentsVersion;
  bool get hasTranscripts => _pipeline.hasTranscripts;
  set hasTranscripts(bool value) => _pipeline.setHasTranscripts(value);

  List<ConversationPhoto> get photos => _audioTransport.photos;

  List<MessageEvent> get transcriptionServiceStatuses =>
      _pipeline.transcriptionServiceStatuses;
  bool get transcriptServiceReady => _pipeline.transcriptServiceReady;

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

  ServerConversation? _conversation;

  // ---------------------------------------------------------------------------
  // Public API — Recording controls
  // ---------------------------------------------------------------------------

  @override
  void updateRecordingState(RecordingState state) {
    _stateMachine.transition(state);
    CaptureProvider.isRecordingWithPhoneMic =
        _stateMachine.isRecordingWithPhoneMic;
    notifyListeners();
    _lifecycle.broadcastRecordingState();
    _lifecycle.updateForegroundNotification(_getNotificationState());
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
  // Phone mic recording
  // ---------------------------------------------------------------------------

  Future<void> streamRecording() async {
    updateRecordingState(RecordingState.initialising);

    final userId = SupabaseAuthService.instance.maityUserId;
    final sessionId = const Uuid().v4();
    _stateMachine.startSession(
      source: RecordingSource.phoneMic,
      sessionId: sessionId,
      userId: userId,
    );

    _captureLog.startSession(
      sessionId,
      getRecordingState: () => recordingState.name,
      getSegmentCount: () => segments.length,
      getSocketState: () => _pipeline.socket?.state.name ?? 'null',
    );
    _captureLog.log('recording', 'recording_started', details: {
      'source': 'phone_mic',
      'codec': 'pcm16',
      'sample_rate': 16000,
    });

    _pipeline.startHealthMonitor();

    // Set up socket sender for audio transport
    _audioTransport.setSocketSender((bytes) {
      _pipeline.sendToSocket(bytes);
      _pipeline.updateLastAudioBytesSentAt();
    });

    await _pipeline.initiateWebsocket(
      audioCodec: BleAudioCodec.pcm16,
      sampleRate: 16000,
      source: ConversationSource.phone.name,
    );

    // Set VAD reference for audio transport
    _audioTransport.setVadService(null); // VAD is handled inside pipeline

    await _audioTransport.startPhoneMicRecording(
      onStateChange: (state) => updateRecordingState(state),
      socketState: () =>
          _pipeline.socket?.state ?? SocketServiceState.disconnected,
    );
  }

  Future<void> stopStreamRecording() async {
    CaptureProvider.isRecordingWithPhoneMic = false;
    _pipeline.cancelSilenceTimer();
    _captureLog.log('recording', 'recording_stop_requested',
        details: {'source': 'phone_mic'});
    _pipeline.stopHealthMonitor();

    await _finalizeLocalConversation();

    _audioTransport.stopPhoneMicRecording();
    updateRecordingState(RecordingState.stop);
    await _pipeline.stopSocket('stop stream recording');
    _captureLog.endSession();
  }

  // ---------------------------------------------------------------------------
  // BLE device recording
  // ---------------------------------------------------------------------------

  Future<void> streamDeviceRecording({BtDevice? device}) async {
    if (device != null) updateRecordingDevice(device);

    final userId = SupabaseAuthService.instance.maityUserId;
    final sessionId = const Uuid().v4();
    _stateMachine.startSession(
      source: RecordingSource.bleDevice,
      sessionId: sessionId,
      userId: userId,
    );

    _captureLog.startSession(
      sessionId,
      getRecordingState: () => recordingState.name,
      getSegmentCount: () => segments.length,
      getSocketState: () => _pipeline.socket?.state.name ?? 'null',
    );
    _captureLog.log('recording', 'recording_started', details: {
      'source': 'ble_device',
      'device_id': device?.id,
      'device_name': device?.name,
      'device_type': device?.type.name,
    });

    _pipeline.startHealthMonitor();

    bool wasPaused = _stateMachine.isPaused;
    await _resetStateVariables();
    await _resetState();
    if (wasPaused) await pauseDeviceRecording();
  }

  Future<void> stopStreamDeviceRecording({bool cleanDevice = false}) async {
    _pipeline.cancelSilenceTimer();
    _captureLog.log('recording', 'recording_stop_requested',
        details: {'source': 'ble_device'});
    _pipeline.stopHealthMonitor();

    await _finalizeLocalConversation();
    await _cleanupCurrentState();

    if (cleanDevice) updateRecordingDevice(null);
    updateRecordingState(RecordingState.stop);
    await _pipeline.stopSocket('stop stream device recording');
    _captureLog.endSession();
  }

  Future<void> pauseDeviceRecording() async {
    if (_audioTransport.recordingDevice == null) return;
    _captureLog.log('recording', 'recording_paused',
        details: {'source': 'ble_device'});
    await _audioTransport.closeBleStream();
    _stateMachine.transition(RecordingState.pause);
    updateRecordingState(RecordingState.pause);
  }

  Future<void> resumeDeviceRecording() async {
    if (_audioTransport.recordingDevice == null) return;
    _captureLog.log('recording', 'recording_resumed',
        details: {'source': 'ble_device'});
    _stateMachine.transition(RecordingState.deviceRecord);
    await _audioTransport.startDeviceAudioStreaming();
    updateRecordingState(RecordingState.deviceRecord);
  }

  // ---------------------------------------------------------------------------
  // System audio recording (desktop)
  // ---------------------------------------------------------------------------

  @override
  Future<void> streamSystemAudioRecording() async {
    if (!PlatformService.isDesktop) {
      notifyError('System audio recording is only available on macOS and Windows.');
      return;
    }

    final userId = SupabaseAuthService.instance.maityUserId;
    final sessionId = const Uuid().v4();
    _stateMachine.startSession(
      source: RecordingSource.systemAudio,
      sessionId: sessionId,
      userId: userId,
    );
    _stateMachine.shouldAutoResumeAfterWake = true;

    _captureLog.startSession(
      sessionId,
      getRecordingState: () => recordingState.name,
      getSegmentCount: () => segments.length,
      getSocketState: () => _pipeline.socket?.state.name ?? 'null',
    );
    _captureLog.log('recording', 'recording_started', details: {
      'source': 'system_audio',
      'codec': 'pcm16',
      'sample_rate': 16000,
    });

    _pipeline.startHealthMonitor();

    await _audioTransport.startSystemAudioRecording(
      onStateChange: (state) => updateRecordingState(state),
      socketState: () =>
          _pipeline.socket?.state ?? SocketServiceState.disconnected,
    );
  }

  Future<void> stopSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;

    _captureLog.log('recording', 'recording_stop_requested',
        details: {'source': 'system_audio'});
    _pipeline.stopHealthMonitor();
    await _finalizeLocalConversation();

    _stateMachine.shouldAutoResumeAfterWake = false;
    _audioTransport.stopSystemAudioRecording();
    await _pipeline.stopSocket('manual stop');
    await _cleanupCurrentState();
    _captureLog.endSession();
  }

  Future<void> pauseSystemAudioRecording({bool isAuto = false}) async {
    if (!PlatformService.isDesktop) return;
    if (!isAuto) _stateMachine.shouldAutoResumeAfterWake = false;
    _audioTransport.pauseSystemAudioRecording(isAuto: isAuto);
    _stateMachine.transition(RecordingState.pause);
    notifyListeners();
  }

  Future<void> resumeSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;
    _stateMachine.shouldAutoResumeAfterWake = true;
    _stateMachine.transition(RecordingState.systemAudioRecord);
    await streamSystemAudioRecording();
  }

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
  // Transcription settings changes
  // ---------------------------------------------------------------------------

  Future<void> onRecordProfileSettingChanged() async {
    await _resetState();
  }

  Future<void> onTranscriptionSettingsChanged() async {
    final device = _audioTransport.recordingDevice;
    if (device != null) {
      await _pipeline.stopSocket('transcription settings changed');
      BleAudioCodec codec = await _getAudioCodec(device.id);
      await _pipeline.initiateWebsocket(
        audioCodec: codec,
        force: true,
        source: _getConversationSourceFromDevice(),
      );
      return;
    }
    if (recordingState == RecordingState.record) {
      await _pipeline.stopSocket('transcription settings changed');
      await _pipeline.initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.phone.name,
      );
      return;
    }
    if (recordingState == RecordingState.systemAudioRecord) {
      await _pipeline.stopSocket('transcription settings changed');
      await _pipeline.initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.desktop.name,
      );
    }
  }

  Future<void> onVadSettingsChanged() async {
    if (recordingState == RecordingState.record ||
        recordingState == RecordingState.systemAudioRecord) {
      final customSttConfig = SharedPreferencesUtil().customSttConfig;
      final effectiveConfig =
          customSttConfig.isEnabled ? customSttConfig : null;
      await _pipeline.initializeVadService(BleAudioCodec.pcm16, effectiveConfig);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Force processing / finalize
  // ---------------------------------------------------------------------------

  Future<void> forceProcessingCurrentConversation() async {
    await _finalizeLocalConversation();
    if (!_stateMachine.finalizeInProgress) {
      _resetStateVariables();
    }
  }

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

      if (_conversation == null) return;

      final isAssigningToUser = finalPersonId == 'user';
      for (var segment in segments) {
        if (segmentIds.contains(segment.id)) {
          segment.isUser = isAssigningToUser;
          segment.personId = isAssigningToUser ? null : finalPersonId;
        }
      }

      await assignBulkConversationTranscriptSegments(
        _conversation!.id,
        segmentIds,
        isUser: isAssigningToUser,
        personId: isAssigningToUser ? null : finalPersonId,
      );

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
  // Refresh
  // ---------------------------------------------------------------------------

  Future<void> refreshInProgressConversations() async {
    await _pipeline.refreshInProgressConversations();
  }

  // ---------------------------------------------------------------------------
  // AppLifecycleDelegate implementation
  // ---------------------------------------------------------------------------

  @override
  bool get conversationFinalized => _stateMachine.conversationFinalized;
  @override
  List<TranscriptSegment> get currentSegments => segments;
  @override
  String? get draftId => _persistence.draftId;
  @override
  bool get isSpeechProfileMode => _stateMachine.isSpeechProfileMode;
  @override
  SocketServiceState? get socketState => _pipeline.socket?.state;

  @override
  Future<void> stopHealthMonitor() async => _pipeline.stopHealthMonitor();
  @override
  void cancelKeepAlive() => _pipeline.stopKeepAlive();
  @override
  void cancelSilenceTimer() => _pipeline.cancelSilenceTimer();
  @override
  void startMetricsTracking() => _audioTransport.startMetricsTracking();
  @override
  Future<void> startHealthMonitor() async => _pipeline.startHealthMonitor();
  @override
  Future<void> reconnectSocket() async => _reconnectForStall();
  @override
  void startKeepAlive() {} // Handled internally by pipeline
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
  Future<void> stopSocket(String reason) async =>
      _pipeline.stopSocket(reason);
  @override
  Future<void> autoFinalizeOnConnectionLost() async =>
      _autoFinalizeOnConnectionLost();
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
    if (recordingState == RecordingState.initialising) return 'processing';
    if (_audioTransport.recordingDevice != null) return 'device_connected';
    return 'waiting';
  }

  String? _getConversationSourceFromDevice() {
    final device = _audioTransport.recordingDevice;
    if (device == null) return null;
    switch (device.type) {
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

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection =
        await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return BleAudioCodec.pcm8;
    return connection.getAudioCodec();
  }

  Future<void> _resetState() async {
    await _cleanupCurrentState();
    if (_audioTransport.recordingDevice != null) {
      await _pipeline.initiateWebsocket(
        audioCodec: await _getAudioCodec(_audioTransport.recordingDevice!.id),
        force: true,
        source: _getConversationSourceFromDevice(),
      );
      await _audioTransport.startDeviceAudioStreaming();
    }
    notifyListeners();
  }

  Future<void> _cleanupCurrentState() async {
    _pipeline.cancelSilenceTimer();
    await _audioTransport.closeBleStream();
    _pipeline.flushVad();
    notifyListeners();
  }

  Future<void> _resetStateVariables() async {
    _pipeline.clearSegments();
    _audioTransport.photos.clear();
    suggestionsBySegmentId = {};
    taggingSegmentIds = [];
    _conversation = null;
    _stateMachine.endSession();
    CaptureProvider.isRecordingWithPhoneMic = false;
    _persistence.reset();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Callbacks from TranscriptionPipeline
  // ---------------------------------------------------------------------------

  void _onNewSegments(List<TranscriptSegment> newSegments) {
    // Schedule recovery save
    _persistence.scheduleRecoverySave(
      segments,
      _stateMachine.currentSessionId,
      _stateMachine.recordingStartTime,
      _stateMachine.isSpeechProfileMode,
    );

    // Schedule incremental save to Supabase
    _persistence.scheduleIncrementalSave(
      segments,
      _stateMachine.cachedRecordingUserId ??
          SupabaseAuthService.instance.maityUserId,
      _stateMachine.recordingStartTime,
      _stateMachine.isSpeechProfileMode,
    );

    // Track new segments for persistence
    _persistence.onSegmentsUpdated(newSegments.length);

    // Trim old saved segments
    final trimmed = _persistence.trimSavedSegments(segments);
    if (trimmed > 0) {
      // Segments list was modified in place
    }
  }

  void _onMessageEvent(MessageEvent event) {
    if (event is ConversationProcessingStartedEvent) {
      conversationProvider!.addProcessingConversation(event.memory);
      _resetStateVariables();
      return;
    }
    if (event is ConversationEvent) {
      event.memory.isNew = true;
      conversationProvider!.removeProcessingConversation(event.memory.id);
      _processConversationCreated(
          event.memory, event.messages.cast<ServerMessage>());
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
    if (event is PhotoProcessingEvent) {
      final idx = photos.indexWhere((p) => p.id == event.tempId);
      if (idx != -1) {
        photos[idx].id = event.photoId;
        notifyListeners();
      }
      return;
    }
    if (event is PhotoDescribedEvent) {
      final idx = photos.indexWhere((p) => p.id == event.photoId);
      if (idx != -1) {
        photos[idx].description = event.description;
        photos[idx].discarded = event.discarded;
        notifyListeners();
      }
      return;
    }
  }

  void _onSilenceTimeout() async {
    if (segments.isEmpty) {
      await stopStreamRecording();
      return;
    }

    // Save recovery data before silence timeout finalize
    if (segments.isNotEmpty && _stateMachine.currentSessionId != null) {
      await _persistence.saveRecoveryData(
        segments,
        _stateMachine.currentSessionId!,
        _stateMachine.recordingStartTime ?? DateTime.now(),
      );
    }

    await _finalizeLocalConversation();
    if (!_stateMachine.finalizeInProgress) {
      _resetStateVariables();
    }
    updateRecordingState(RecordingState.stop);
  }

  Future<void> _reconnectForStall() async {
    await _pipeline.stopSocket('transcription stalled');
    if (recordingState == RecordingState.record) {
      await _pipeline.initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.phone.name,
      );
    } else if (recordingState == RecordingState.deviceRecord &&
        _audioTransport.recordingDevice != null) {
      BleAudioCodec codec =
          await _getAudioCodec(_audioTransport.recordingDevice!.id);
      await _pipeline.initiateWebsocket(
          audioCodec: codec,
          force: true,
          source: _getConversationSourceFromDevice());
    } else if (recordingState == RecordingState.systemAudioRecord) {
      await _pipeline.initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        force: true,
        source: ConversationSource.desktop.name,
      );
    }
  }

  Future<void> _autoFinalizeOnConnectionLost() async {
    if (segments.isEmpty || _stateMachine.conversationFinalized) return;

    _captureLog.log('recording', 'auto_finalize_connection_lost',
        severity: 'warning',
        details: {
          'segments_count': segments.length,
          'has_draft': _persistence.draftId != null,
        });

    // Save recovery as backup
    if (_stateMachine.currentSessionId != null) {
      await _persistence.saveRecoveryData(
        segments,
        _stateMachine.currentSessionId!,
        _stateMachine.recordingStartTime ?? DateTime.now(),
        synchronous: true,
      );
    }

    await _pipeline.stopSocket('connection lost - auto finalizing');
    ServiceManager.instance().mic.stop();
    CaptureProvider.isRecordingWithPhoneMic = false;
    _pipeline.stopHealthMonitor();
    _pipeline.cancelSilenceTimer();

    await _finalizeLocalConversation();
    await _resetStateVariables();
    updateRecordingState(RecordingState.stop);
    _captureLog.endSession();
    notifyListeners();
  }

  Future<void> _finalizeLocalConversation() async {
    final success = await _persistence.finalizeConversation(
      segments: List.from(segments),
      userId: _stateMachine.cachedRecordingUserId ??
          SupabaseAuthService.instance.maityUserId,
      startedAt: _stateMachine.recordingStartTime,
      isSpeechProfileMode: _stateMachine.isSpeechProfileMode,
      onSuccess: () {
        conversationProvider?.refreshConversations();
      },
      totalSegmentCount: _persistence.totalSegmentCount,
    );

    if (success) {
      _stateMachine.conversationFinalized = true;
    }
  }

  // ---------------------------------------------------------------------------
  // Message event handlers (preserved from original)
  // ---------------------------------------------------------------------------

  Future<void> _processConversationCreated(
      ServerConversation? conversation, List<ServerMessage> messages) async {
    if (conversation == null) return;
    conversationProvider?.upsertConversation(conversation);
    MixpanelManager().conversationCreated(conversation);
  }

  Future<void> _handleLastConvoEvent(String memoryId) async {
    bool exists = conversationProvider?.conversations
            .any((c) => c.id == memoryId) ??
        false;
    if (exists) return;
    ServerConversation? conversation = await getConversationById(memoryId);
    if (conversation != null) {
      conversationProvider?.upsertConversation(conversation);
    }
  }

  void _handleTranslationEvent(List<TranscriptSegment> translatedSegments) {
    if (translatedSegments.isEmpty) return;
    TranscriptSegment.updateSegments(segments, translatedSegments);
    notifyListeners();
  }

  void _handleSpeakerLabelSuggestionEvent(SpeakerLabelSuggestionEvent event) {
    if (taggingSegmentIds.contains(event.segmentId)) return;
    var segment = segments.firstWhereOrNull((s) => s.id == event.segmentId);
    if (segment != null &&
        segment.id.isNotEmpty &&
        (segment.personId != null || segment.isUser)) {
      return;
    }
    if (SharedPreferencesUtil().autoCreateSpeakersEnabled) {
      assignSpeakerToConversation(
          event.speakerId, event.personId, event.personName, [event.segmentId]);
    } else {
      suggestionsBySegmentId[event.segmentId] = event;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Audio record profile changes
  // ---------------------------------------------------------------------------

  Future<void> changeAudioRecordProfile({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    String? source,
  }) async {
    await _resetState();
    await _pipeline.initiateWebsocket(
        audioCodec: audioCodec,
        sampleRate: sampleRate,
        channels: channels,
        isPcm: isPcm,
        source: source);
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    debugPrint('[CaptureProvider] dispose() called');
    _connectionStateListener?.cancel();
    _audioTransport.dispose();
    _pipeline.dispose();
    _persistence.dispose();
    _lifecycle.dispose();
    _stateMachine.dispose();
    super.dispose();
  }
}
