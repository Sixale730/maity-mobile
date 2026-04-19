import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/notifications/notification_service.dart';
import 'package:omi/services/platform_logger.dart';
import 'package:omi/services/recording/audio_transport_service.dart';
import 'package:omi/services/recording/persistence_manager.dart';
import 'package:omi/services/recording/recording_state_machine.dart';
import 'package:omi/services/recording/session_lifecycle_manager.dart';
import 'package:omi/services/recording/session_snapshot.dart';
import 'package:omi/services/recording/telemetry_collector.dart';
import 'package:omi/services/recording/telemetry_sender.dart';
import 'package:omi/services/recording/transcription_pipeline.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/speaker/heuristic_correction.dart';
import 'package:omi/services/speaker/speaker_types.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart';
import 'package:omi/services/stt/local/device_memory_service.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:uuid/uuid.dart';

const _autoSaveNotificationMessages = {
  'en': {
    'title': 'Conversation Saved',
    'body':
        'Your conversation was saved automatically due to silence and is being processed.',
  },
  'es': {
    'title': 'Conversacion Guardada',
    'body':
        'Tu conversacion fue guardada automaticamente por silencio y se esta procesando.',
  },
};

/// Manages all recording start/stop/pause/resume/cancel logic.
///
/// Extracted from CaptureProvider to keep it thin. Uses callback-based
/// decoupling so CaptureProvider can handle ChangeNotifier updates,
/// foreground notifications, and desktop broadcasts.
class RecordingController {
  // ---------------------------------------------------------------------------
  // Dependencies (injected)
  // ---------------------------------------------------------------------------

  final RecordingStateMachine _stateMachine;
  final AudioTransportService _audioTransport;
  final TranscriptionPipeline _pipeline;
  final PersistenceManager _persistence;
  final SessionLifecycleManager _sessionLifecycle;

  // ---------------------------------------------------------------------------
  // Callbacks to CaptureProvider
  // ---------------------------------------------------------------------------

  /// Called when the recording state should be updated (triggers notification,
  /// desktop broadcast, widget sync, etc. in CaptureProvider).
  void Function(RecordingState state)? onRecordingStateChanged;

  /// Called to trigger ChangeNotifier.notifyListeners() in CaptureProvider.
  VoidCallback? onNotifyListeners;

  /// Called after a conversation is finalized and state reset to decide
  /// whether to auto-restart recording (continuous BLE recording).
  void Function(bool wasPaused)? onAutoRestartNeeded;

  /// Called to refresh conversations after finalize completes.
  VoidCallback? onConversationFinalized;

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  /// Completed when recording state transitions to [RecordingState.record].
  Completer<void>? _recordingReadyCompleter;

  /// Tracks whether the recording was paused before auto-save (for restart).
  bool _restartPaused = false;

  /// Single-flight guard for reconnect operations.
  Completer<void>? _reconnectInflight;

  /// Auto-save message notifier (displayed to user).
  final ValueNotifier<String?> autoSaveMessage = ValueNotifier(null);

  CaptureLogService get _captureLog => CaptureLogService.instance;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  RecordingController({
    required RecordingStateMachine stateMachine,
    required AudioTransportService audioTransport,
    required TranscriptionPipeline pipeline,
    required PersistenceManager persistence,
    required SessionLifecycleManager sessionLifecycle,
  })  : _stateMachine = stateMachine,
        _audioTransport = audioTransport,
        _pipeline = pipeline,
        _persistence = persistence,
        _sessionLifecycle = sessionLifecycle;

  // ---------------------------------------------------------------------------
  // Pre-flight checks
  // ---------------------------------------------------------------------------

  /// Returns true if there's enough RAM to start local STT recording.
  Future<bool> _passesPreFlightRamCheck() async {
    final config = SharedPreferencesUtil().customSttConfig;
    if (!config.isEnabled) return true;

    final provider = config.provider;
    if (provider != SttProvider.localParakeet &&
        provider != SttProvider.localMoonshine &&
        provider != SttProvider.localCanary) {
      return true;
    }

    final result = await DeviceMemoryService.canStartRecording();
    if (!result.canStart) {
      debugPrint('[RecordingController] Pre-flight RAM check failed: '
          '${result.availableMb}MB available '
          '(min ${DeviceMemoryService.minRamForRecordingMb}MB)');
      TelemetryCollector.instance.recordStreamingEvent(
        'ram_check_failed',
        details: {
          'available_mb': result.availableMb,
          'required_mb': DeviceMemoryService.minRamForRecordingMb,
        },
      );
      NotificationService.instance.createNotification(
        title: 'Memoria insuficiente',
        body:
            'La grabacion no puede iniciar: solo ${result.availableMb}MB libres '
            '(minimo ${DeviceMemoryService.minRamForRecordingMb}MB). '
            'Cierra otras apps e intenta de nuevo.',
        notificationId: 5,
      );
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Common session setup (extracted from 3 start flows)
  // ---------------------------------------------------------------------------

  /// Common session initialization for all audio sources.
  /// Returns sessionId, or empty string if pre-flight check fails.
  Future<String> _initSession({
    required RecordingSource source,
    required String audioSourceName,
    Map<String, dynamic>? logDetails,
  }) async {
    if (!await _passesPreFlightRamCheck()) {
      debugPrint('[RecordingController] Recording blocked: insufficient RAM');
      return '';
    }

    onRecordingStateChanged?.call(RecordingState.initialising);

    final userId = SupabaseAuthService.instance.maityUserId;
    final sessionId = const Uuid().v4();
    _stateMachine.startSession(
      source: source,
      sessionId: sessionId,
      userId: userId,
    );
    _sessionLifecycle.startSession();
    TelemetryCollector.instance.startSession(
      sessionId: sessionId,
      audioSource: audioSourceName,
      startedAt: _stateMachine.recordingStartTime,
    );

    PlatformLogger.instance.logEvent('recording.started', data: {
      'audio_source': audioSourceName,
      'recording_session_id': sessionId,
    });

    _captureLog.startSession(
      sessionId,
      getRecordingState: () => _stateMachine.state.name,
      getSegmentCount: () => _pipeline.displaySegments.length,
      getSocketState: () => _pipeline.socket?.state.name ?? 'null',
    );
    _captureLog.log('recording', 'recording_started',
        details: logDetails ?? {'source': audioSourceName});

    _pipeline.startHealthMonitor();
    _pipeline.setWalEnabled(true);
    _pipeline.chunkSessionId = sessionId;
    _setupSocketSender();

    return sessionId;
  }

  /// Wire the audio transport socket sender to the pipeline.
  void _setupSocketSender() {
    _audioTransport.setSocketSender((bytes) {
      _pipeline.sendToSocket(bytes);
      _pipeline.updateLastAudioBytesSentAt();
      _sessionLifecycle.markAudioReceived();
      _pipeline.setExternalAudioFlowTimestamp(
          _sessionLifecycle.lastAudioReceivedAt);
    });
  }

  // ---------------------------------------------------------------------------
  // Common stop + snapshot (extracted from 3+ stop flows)
  // ---------------------------------------------------------------------------

  /// Stop recording and capture a snapshot of ALL segments before engine
  /// disposal. Returns the snapshot for finalization, or null if the session
  /// state is invalid (sessionId, startedAt, or source missing).
  Future<SessionSnapshot?> _stopWithSnapshot(String reason) async {
    _pipeline.cancelSilenceTimer();
    _captureLog.log('recording', 'recording_stop_requested',
        details: {'reason': reason});
    _pipeline.stopHealthMonitor();
    TelemetryCollector.instance.markStopped();

    _sessionLifecycle.transition(SessionPhase.stopping);

    // Capture ALL segments while orchestrator is still alive
    final segCtrl = _pipeline.localOrchestrator?.segmentController;
    final allSegments = segCtrl != null
        ? await segCtrl.collectAllSegments()
        : List<TranscriptSegment>.from(_pipeline.segments);

    onRecordingStateChanged?.call(RecordingState.processing);

    final sessionId = _stateMachine.currentSessionId;
    final startedAt = _stateMachine.recordingStartTime;
    final source = _stateMachine.source;
    if (sessionId == null || startedAt == null || source == null) {
      debugPrint(
          '[RecordingController] _stopWithSnapshot: session state invalid '
          '(sid=$sessionId, start=$startedAt, src=$source)');
      _captureLog.log('recording', 'stop_with_invalid_session',
          severity: 'error',
          details: {
            'reason': reason,
            'session_id': sessionId,
            'source': source?.name,
          });
      return null;
    }

    return SessionSnapshot(
      sessionId: sessionId,
      allSegments: allSegments,
      startedAt: startedAt,
      stoppedAt: DateTime.now(),
      userId: _stateMachine.cachedRecordingUserId ??
          SupabaseAuthService.instance.maityUserId,
      idempotencyKey: _sessionLifecycle.deriveIdempotencyKey(sessionId),
      source: source,
    );
  }

  // ---------------------------------------------------------------------------
  // Phone mic recording
  // ---------------------------------------------------------------------------

  /// Start phone microphone recording.
  ///
  /// Awaits until the mic callback fires [RecordingState.record] (or times out).
  Future<void> streamRecording() async {
    final sessionId = await _initSession(
      source: RecordingSource.phoneMic,
      audioSourceName: 'phone_mic',
      logDetails: {
        'source': 'phone_mic',
        'codec': 'pcm16',
        'sample_rate': 16000,
      },
    );
    if (sessionId.isEmpty) return;

    _recordingReadyCompleter = Completer<void>();

    try {
      await _pipeline.initiateWebsocket(
        audioCodec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        source: ConversationSource.phone.name,
      );

      _audioTransport.setVadService(null);

      await _audioTransport.startPhoneMicRecording(
        onStateChange: (state) => onRecordingStateChanged?.call(state),
        socketState: () =>
            _pipeline.socket?.state ?? SocketServiceState.disconnected,
      );
    } catch (e) {
      debugPrint('[RecordingController] streamRecording failed: $e');
      _captureLog.log('recording', 'stream_recording_failed',
          severity: 'error', details: {'error': e.toString()});
      _pipeline.stopHealthMonitor();
      _audioTransport.setSocketSender(null);
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
      _recordingReadyCompleter = null;
      return;
    }

    // Wait until the mic callback fires RecordingState.record.
    try {
      await _recordingReadyCompleter!.future
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      debugPrint('[RecordingController] Timed out waiting for mic to start');
      _captureLog.log('recording', 'mic_start_timeout', severity: 'error');
      _pipeline.stopHealthMonitor();
      _audioTransport.stopPhoneMicRecording();
      _audioTransport.setSocketSender(null);
      _pipeline.stopSocket('mic start timeout');
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
    } catch (_) {
      // Completer was completed with error (stop/error state) -- already handled.
    } finally {
      _recordingReadyCompleter = null;
    }
  }

  /// Stop phone microphone recording.
  Future<void> stopStreamRecording() async {
    final snapshot = await _stopWithSnapshot('stop phone mic');
    _audioTransport.stopPhoneMicRecording();
    _pipeline.stopSocket('stop stream recording');
    if (snapshot == null) {
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
      return;
    }
    _sessionLifecycle.setSnapshot(snapshot);
    _backgroundFinalizeWithSnapshot(snapshot);
  }

  // ---------------------------------------------------------------------------
  // BLE device recording
  // ---------------------------------------------------------------------------

  /// Start BLE device recording.
  Future<void> streamDeviceRecording({BtDevice? device}) async {
    if (device != null) _audioTransport.updateRecordingDevice(device);
    if (_audioTransport.recordingDevice == null) {
      debugPrint('[RecordingController] streamDeviceRecording: no device available, skipping');
      return;
    }

    final sessionId = await _initSession(
      source: RecordingSource.bleDevice,
      audioSourceName: 'ble',
      logDetails: {
        'source': 'ble_device',
        'device_id': device?.id,
        'device_name': device?.name,
        'device_type': device?.type.name,
      },
    );
    if (sessionId.isEmpty) return;

    try {
      _pipeline.clearSegments();
      _audioTransport.photos.clear();
      await _resetState();
    } catch (e) {
      debugPrint('[RecordingController] streamDeviceRecording failed: $e');
      _captureLog.log('recording', 'stream_device_recording_failed',
          severity: 'error', details: {'error': e.toString()});
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
    }
  }

  /// Stop BLE device recording.
  Future<void> stopStreamDeviceRecording({bool cleanDevice = false}) async {
    final snapshot = await _stopWithSnapshot('stop BLE device');
    await _cleanupCurrentState();
    if (cleanDevice) _audioTransport.updateRecordingDevice(null);
    _pipeline.stopSocket('stop stream device recording');
    if (snapshot == null) {
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
      return;
    }
    _sessionLifecycle.setSnapshot(snapshot);
    _backgroundFinalizeWithSnapshot(snapshot);
  }

  /// Pause BLE device recording.
  Future<void> pauseDeviceRecording() async {
    if (_audioTransport.recordingDevice == null) return;
    _captureLog.log('recording', 'recording_paused',
        details: {'source': 'ble_device'});
    await _audioTransport.closeBleStream();
    _stateMachine.transition(RecordingState.pause);
    onRecordingStateChanged?.call(RecordingState.pause);
    _pipeline.resetSilenceTimer();
  }

  /// Resume BLE device recording.
  Future<void> resumeDeviceRecording() async {
    if (_audioTransport.recordingDevice == null) return;
    _captureLog.log('recording', 'recording_resumed',
        details: {'source': 'ble_device'});
    _stateMachine.transition(RecordingState.deviceRecord);
    await _audioTransport.startDeviceAudioStreaming();
    onRecordingStateChanged?.call(RecordingState.deviceRecord);
  }

  // ---------------------------------------------------------------------------
  // Phone mic pause/resume
  // ---------------------------------------------------------------------------

  /// Pause phone mic recording without finalizing.
  Future<void> pausePhoneMicRecording() async {
    _captureLog.log('recording', 'recording_paused',
        details: {'source': 'phone_mic'});
    PlatformLogger.instance
        .logEvent('recording.paused', data: {'audio_source': 'phone_mic'});
    _audioTransport.stopPhoneMicRecording();
    _stateMachine.transition(RecordingState.pause);
    onRecordingStateChanged?.call(RecordingState.pause);
    _pipeline.resetSilenceTimer();
  }

  /// Resume phone mic recording.
  Future<void> resumePhoneMicRecording() async {
    _captureLog.log('recording', 'recording_resumed',
        details: {'source': 'phone_mic'});
    PlatformLogger.instance
        .logEvent('recording.resumed', data: {'audio_source': 'phone_mic'});
    _stateMachine.transition(RecordingState.record);
    onRecordingStateChanged?.call(RecordingState.initialising);

    _pipeline.setWalEnabled(true);
    _audioTransport.setSocketSender(_pipeline.sendToSocket);

    await _audioTransport.startPhoneMicRecording(
      onStateChange: (state) => onRecordingStateChanged?.call(state),
      socketState: () =>
          _pipeline.socket?.state ?? SocketServiceState.disconnected,
    );
  }

  // ---------------------------------------------------------------------------
  // System audio recording (desktop)
  // ---------------------------------------------------------------------------

  /// Start system audio recording (desktop only).
  Future<void> streamSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;

    final sessionId = await _initSession(
      source: RecordingSource.systemAudio,
      audioSourceName: 'system_audio',
      logDetails: {
        'source': 'system_audio',
        'codec': 'pcm16',
        'sample_rate': 16000,
      },
    );
    if (sessionId.isEmpty) return;

    _stateMachine.shouldAutoResumeAfterWake = true;

    try {
      await _audioTransport.startSystemAudioRecording(
        onStateChange: (state) => onRecordingStateChanged?.call(state),
        socketState: () =>
            _pipeline.socket?.state ?? SocketServiceState.disconnected,
      );
    } catch (e) {
      debugPrint(
          '[RecordingController] streamSystemAudioRecording failed: $e');
      _captureLog.log('recording', 'stream_system_audio_failed',
          severity: 'error', details: {'error': e.toString()});
      _pipeline.stopHealthMonitor();
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
    }
  }

  /// Stop system audio recording.
  Future<void> stopSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;

    final snapshot = await _stopWithSnapshot('stop system audio');
    _stateMachine.shouldAutoResumeAfterWake = false;
    _audioTransport.stopSystemAudioRecording();
    _pipeline.stopSocket('manual stop');
    await _cleanupCurrentState();
    if (snapshot == null) {
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
      return;
    }
    _sessionLifecycle.setSnapshot(snapshot);
    _backgroundFinalizeWithSnapshot(snapshot);
  }

  /// Pause system audio recording.
  Future<void> pauseSystemAudioRecording({bool isAuto = false}) async {
    if (!PlatformService.isDesktop) return;
    if (!isAuto) _stateMachine.shouldAutoResumeAfterWake = false;
    PlatformLogger.instance.logEvent('recording.paused',
        data: {'audio_source': 'system_audio', 'is_auto': isAuto});
    _audioTransport.pauseSystemAudioRecording(isAuto: isAuto);
    _stateMachine.transition(RecordingState.pause);
    _pipeline.resetSilenceTimer();
    onNotifyListeners?.call();
  }

  /// Resume system audio recording.
  Future<void> resumeSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;
    PlatformLogger.instance
        .logEvent('recording.resumed', data: {'audio_source': 'system_audio'});
    _stateMachine.shouldAutoResumeAfterWake = true;
    _stateMachine.transition(RecordingState.systemAudioRecord);
    await streamSystemAudioRecording();
  }

  // ---------------------------------------------------------------------------
  // Cancel
  // ---------------------------------------------------------------------------

  /// Cancel an active recording that has no segments.
  /// If segments arrived in the meantime, delegates to the normal stop flow.
  Future<void> cancelRecording() async {
    final segments = _pipeline.displaySegments;
    if (segments.isNotEmpty) {
      if (_stateMachine.state == RecordingState.systemAudioRecord) {
        await stopSystemAudioRecording();
      } else if (_stateMachine.state == RecordingState.deviceRecord) {
        await stopStreamDeviceRecording();
      } else {
        await stopStreamRecording();
      }
      return;
    }

    debugPrint(
        '[RecordingController] cancelRecording: no segments, stopping without finalize');
    _captureLog.log('recording', 'recording_cancelled',
        details: {'reason': 'user_cancel_no_segments'});

    _pipeline.stopHealthMonitor();
    _pipeline.cancelSilenceTimer();
    await _cleanupCurrentState();
    _audioTransport.stopPhoneMicRecording();
    if (PlatformService.isDesktop) {
      _audioTransport.stopSystemAudioRecording();
    }
    _pipeline.stopSocket('user cancel - no segments');
    onRecordingStateChanged?.call(RecordingState.stop);
    _flushDiscardedTelemetry();
    await _resetStateVariables();
    _captureLog.endSession();
  }

  // ---------------------------------------------------------------------------
  // Silence timeout handler
  // ---------------------------------------------------------------------------

  /// Called by TranscriptionPipeline when silence timeout fires.
  Future<void> onSilenceTimeout() async {
    final segments = _pipeline.displaySegments;
    if (segments.isEmpty) {
      debugPrint(
          '[RecordingController] Silence timeout with no segments, stopping without finalize');
      _pipeline.stopHealthMonitor();
      await _cleanupCurrentState();
      _audioTransport.stopPhoneMicRecording();
      _pipeline.stopSocket('silence timeout - no segments');
      onRecordingStateChanged?.call(RecordingState.stop);
      _flushDiscardedTelemetry();
      _sessionLifecycle.reset();
      await _resetStateVariables();
      return;
    }

    // Capture pause state before FSM transitions clear it
    _restartPaused = _stateMachine.isPaused;

    _captureLog.log('recording', 'silence_timeout_auto_save', details: {
      'segments_count': segments.length,
      'was_paused': _restartPaused,
    });

    final snapshot = await _stopWithSnapshot('silence timeout auto-save');

    // Stop remaining audio (regardless of snapshot validity)
    await _cleanupCurrentState();
    _audioTransport.stopPhoneMicRecording();
    _pipeline.stopSocket('silence timeout auto-save');

    if (snapshot == null) {
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
      return;
    }

    // Save recovery data as backup (with the FULL segments)
    if (_stateMachine.currentSessionId != null) {
      await _persistence.saveRecoveryData(
        snapshot.allSegments,
        _stateMachine.currentSessionId!,
        _stateMachine.recordingStartTime ?? DateTime.now(),
      );
    }

    // Notify user
    _showAutoSaveNotification();
    final lang = SharedPreferencesUtil().appLanguage;
    autoSaveMessage.value = lang == 'es'
        ? 'Conversacion guardada por silencio'
        : 'Conversation saved due to silence';

    _sessionLifecycle.setSnapshot(snapshot);
    _backgroundFinalizeWithSnapshot(snapshot);
  }

  // ---------------------------------------------------------------------------
  // Reconnect for stall
  // ---------------------------------------------------------------------------

  /// Reconnect the transcription socket when a stall is detected.
  Future<void> reconnectForStall() async {
    // Single-flight: if a reconnect is already in progress, piggyback on it
    if (_reconnectInflight != null) {
      return _reconnectInflight!.future;
    }
    _reconnectInflight = Completer<void>();

    _pipeline.stopKeepAlive();
    _pipeline.setReconnecting(true);
    await _pipeline.stopSocket('transcription stalled');
    try {
      final params = await _reconnectParamsForCurrentState();
      if (params != null) {
        await _pipeline.initiateWebsocket(
          audioCodec: params.codec,
          sampleRate: params.sampleRate,
          force: true,
          source: params.source,
        );
      }
      _reconnectInflight?.complete();
    } catch (e) {
      debugPrint('[RecordingController] reconnectForStall failed: $e');
      _captureLog.log('recording', 'reconnect_for_stall_failed',
          severity: 'error', details: {'error': e.toString()});
      _reconnectInflight?.completeError(e);
    } finally {
      _reconnectInflight = null;
      _pipeline.setReconnecting(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Auto-finalize on connection lost
  // ---------------------------------------------------------------------------

  /// Auto-finalize when connection is lost and segments exist.
  Future<void> autoFinalizeOnConnectionLost() async {
    final segments = _pipeline.displaySegments;
    if (segments.isEmpty || _stateMachine.conversationFinalized) return;
    if (_sessionLifecycle.phase == SessionPhase.stopping ||
        _sessionLifecycle.phase == SessionPhase.finalizing) {
      return;
    }

    _captureLog.log('recording', 'auto_finalize_connection_lost',
        severity: 'warning',
        details: {
          'segments_count': segments.length,
        });

    final snapshot = await _stopWithSnapshot('connection lost auto-finalize');

    await _pipeline.stopSocket('connection lost - auto finalizing');
    await _audioTransport.closeBleStream();
    _pipeline.flushVad();
    ServiceManager.instance().mic.stop();

    if (snapshot == null) {
      await _resetStateVariables();
      onRecordingStateChanged?.call(RecordingState.stop);
      _captureLog.endSession();
      return;
    }

    // Save recovery as backup (with the FULL segments)
    if (_stateMachine.currentSessionId != null) {
      await _persistence.saveRecoveryData(
        snapshot.allSegments,
        _stateMachine.currentSessionId!,
        _stateMachine.recordingStartTime ?? DateTime.now(),
        synchronous: true,
      );
    }

    _sessionLifecycle.setSnapshot(snapshot);
    _backgroundFinalizeWithSnapshot(snapshot);
  }

  // ---------------------------------------------------------------------------
  // Force processing
  // ---------------------------------------------------------------------------

  /// Force processing of current conversation (legacy path without snapshot).
  Future<void> forceProcessingCurrentConversation() async {
    await _finalizeLocalConversation();
    if (!_stateMachine.finalizeInProgress) {
      _resetStateVariables();
    }
  }

  // ---------------------------------------------------------------------------
  // Recording ready completer support
  // ---------------------------------------------------------------------------

  /// Called by CaptureProvider.updateRecordingState to signal the
  /// recording-ready completer when the mic starts or fails.
  void signalRecordingReady(RecordingState state) {
    final c = _recordingReadyCompleter;
    if (c != null && !c.isCompleted) {
      if (state == RecordingState.record) {
        c.complete();
      } else if (state == RecordingState.stop ||
          state == RecordingState.error) {
        c.completeError(StateError('Recording failed to start: $state'));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

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

  /// Returns reconnect parameters for the current recording state, or null
  /// if no reconnect should be attempted.
  Future<_ReconnectParams?> _reconnectParamsForCurrentState() async {
    if (_stateMachine.state == RecordingState.record) {
      return _ReconnectParams(
        codec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        source: ConversationSource.phone.name,
      );
    } else if (_stateMachine.state == RecordingState.deviceRecord &&
        _audioTransport.recordingDevice != null) {
      final codec =
          await _getAudioCodec(_audioTransport.recordingDevice!.id);
      return _ReconnectParams(
        codec: codec,
        source: _getConversationSourceFromDevice(),
      );
    } else if (_stateMachine.state == RecordingState.systemAudioRecord) {
      return _ReconnectParams(
        codec: BleAudioCodec.pcm16,
        sampleRate: 16000,
        source: ConversationSource.desktop.name,
      );
    }
    return null;
  }

  Future<void> _resetState() async {
    await _cleanupCurrentState();
    if (_audioTransport.recordingDevice != null) {
      try {
        await _pipeline.initiateWebsocket(
          audioCodec:
              await _getAudioCodec(_audioTransport.recordingDevice!.id),
          force: true,
          source: _getConversationSourceFromDevice(),
        );
        await _audioTransport.startDeviceAudioStreaming();
        onRecordingStateChanged?.call(RecordingState.deviceRecord);
      } catch (e) {
        debugPrint('[RecordingController] _resetState failed: $e');
        _captureLog.log('recording', 'reset_state_failed',
            severity: 'error', details: {'error': e.toString()});
      }
    }
    onNotifyListeners?.call();
  }

  Future<void> _cleanupCurrentState() async {
    _pipeline.cancelSilenceTimer();
    await _audioTransport.closeBleStream();
    _pipeline.flushVad();
    onNotifyListeners?.call();
  }

  Future<void> _resetStateVariables() async {
    _pipeline.clearSegments();
    _audioTransport.photos.clear();
    _stateMachine.endSession();
    _persistence.reset();
    if (_sessionLifecycle.phase != SessionPhase.idle) {
      _sessionLifecycle.reset();
    }
    onNotifyListeners?.call();
  }

  void _flushDiscardedTelemetry() {
    if (TelemetryCollector.instance.currentSessionId == null) return;
    TelemetryCollector.instance.markStopped();
    final snap = TelemetryCollector.instance.snapshot();
    TelemetrySender.send(snapshot: snap, outcome: 'discarded');
    TelemetryCollector.instance.reset();
  }

  void _showAutoSaveNotification() {
    final lang = SharedPreferencesUtil().appLanguage;
    final messages = _autoSaveNotificationMessages[lang] ??
        _autoSaveNotificationMessages['en']!;
    NotificationService.instance.createNotification(
      title: messages['title']!,
      body: messages['body']!,
      notificationId: 4,
    );
  }

  // ---------------------------------------------------------------------------
  // Heuristic corrections
  // ---------------------------------------------------------------------------

  /// Apply heuristic speaker corrections on a standalone segment list.
  void _applyHeuristicCorrectionsOnList(List<TranscriptSegment> segmentList) {
    final scoredSegments = <ScoredSegment>[];
    for (var i = 0; i < segmentList.length; i++) {
      final seg = segmentList[i];
      if (seg.confidence != null) {
        scoredSegments.add(ScoredSegment(
          index: i,
          text: seg.text,
          speakerId: seg.speakerId,
          confidence: seg.confidence!,
          startTime: seg.start,
          endTime: seg.end,
        ));
      }
    }

    if (scoredSegments.length < 2) return;

    final corrections = applyHeuristicCorrections(scoredSegments);
    if (corrections.isEmpty) return;

    debugPrint(
        '[RecordingController] Applying ${corrections.length} heuristic corrections');

    for (final c in corrections) {
      final seg = segmentList[c.segmentIndex];
      seg.isUser = c.correctedSpeaker == 0;
      seg.speaker = 'SPEAKER_${c.correctedSpeaker}';
      seg.speakerId = c.correctedSpeaker;
      seg.correctionSource = c.correctionSource;
    }
  }

  // ---------------------------------------------------------------------------
  // Finalization
  // ---------------------------------------------------------------------------

  /// Fire-and-forget finalize with a pre-captured snapshot.
  void _backgroundFinalizeWithSnapshot(SessionSnapshot snapshot) {
    _sessionLifecycle.transition(SessionPhase.finalizing);
    final sessionId = _stateMachine.currentSessionId;

    // Apply heuristic corrections on snapshot segments
    _applyHeuristicCorrectionsOnList(snapshot.allSegments);

    _persistence
        .finalizeConversation(
      segments: snapshot.allSegments,
      userId: snapshot.userId,
      startedAt: snapshot.startedAt,
      isSpeechProfileMode: _stateMachine.isSpeechProfileMode,
      sessionId: snapshot.sessionId,
      idempotencyKey: snapshot.idempotencyKey,
      onSuccess: () {
        onConversationFinalized?.call();
      },
    )
        .then((_) {
      debugPrint(
          '[RecordingController] Background finalize completed successfully');
      _stateMachine.conversationFinalized = true;
    }).catchError((e) {
      debugPrint('[RecordingController] Background finalize error: $e');
      _captureLog.log('recording', 'background_finalize_error',
          severity: 'error', details: {'error': e.toString()});
    }).whenComplete(() {
      // Only reset if the session hasn't changed (no new recording started).
      // Require sessionId != null to avoid `null == null → true` when the
      // state machine was already cleared.
      if (sessionId != null && _stateMachine.currentSessionId == sessionId) {
        // Reset recording state but NOT the lifecycle phase — auto-restart
        // needs to transition finalizing → restarting (idle → restarting
        // is invalid in the session FSM).
        _pipeline.clearSegments();
        _audioTransport.photos.clear();
        _stateMachine.endSession();
        _persistence.reset();
        onRecordingStateChanged?.call(RecordingState.stop);
        _captureLog.endSession();

        // Continuous recording: if OMI device still connected, auto-restart.
        // The callback transitions lifecycle: finalizing → restarting → active,
        // or finalizing → idle if no device is available.
        final wasPaused = _restartPaused;
        _restartPaused = false;
        onAutoRestartNeeded?.call(wasPaused);
      } else {
        debugPrint('[RecordingController] Skipping reset: new session started '
            '(old=$sessionId, new=${_stateMachine.currentSessionId})');
      }
    });
  }

  Future<void> _finalizeLocalConversation() async {
    if (_sessionLifecycle.phase == SessionPhase.finalizing) {
      debugPrint(
          '[RecordingController] Finalize already in progress, skipping');
      return;
    }

    // Apply heuristic speaker corrections on full segment list
    final segments = _pipeline.displaySegments;
    _applyHeuristicCorrectionsOnList(List.from(segments));

    await _persistence.finalizeConversation(
      segments: List.from(segments),
      userId: _stateMachine.cachedRecordingUserId ??
          SupabaseAuthService.instance.maityUserId,
      startedAt: _stateMachine.recordingStartTime,
      isSpeechProfileMode: _stateMachine.isSpeechProfileMode,
      sessionId: _stateMachine.currentSessionId,
      onSuccess: () {
        onConversationFinalized?.call();
      },
    );

    _stateMachine.conversationFinalized = true;
  }

  // ---------------------------------------------------------------------------
  // Settings change handlers (delegated from CaptureProvider)
  // ---------------------------------------------------------------------------

  /// Called when transcription settings change.
  Future<void> onTranscriptionSettingsChanged() async {
    try {
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
      if (_stateMachine.state == RecordingState.record) {
        await _pipeline.stopSocket('transcription settings changed');
        await _pipeline.initiateWebsocket(
          audioCodec: BleAudioCodec.pcm16,
          sampleRate: 16000,
          force: true,
          source: ConversationSource.phone.name,
        );
        return;
      }
      if (_stateMachine.state == RecordingState.systemAudioRecord) {
        await _pipeline.stopSocket('transcription settings changed');
        await _pipeline.initiateWebsocket(
          audioCodec: BleAudioCodec.pcm16,
          sampleRate: 16000,
          force: true,
          source: ConversationSource.desktop.name,
        );
      }
    } catch (e) {
      debugPrint(
          '[RecordingController] onTranscriptionSettingsChanged failed: $e');
      _captureLog.log('recording', 'transcription_settings_change_failed',
          severity: 'error', details: {'error': e.toString()});
    }
  }

  /// Called when audio record profile changes.
  Future<void> changeAudioRecordProfile({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
    String? source,
  }) async {
    try {
      await _resetState();
      await _pipeline.initiateWebsocket(
          audioCodec: audioCodec,
          sampleRate: sampleRate,
          channels: channels,
          isPcm: isPcm,
          source: source);
    } catch (e) {
      debugPrint('[RecordingController] changeAudioRecordProfile failed: $e');
      _captureLog.log('recording', 'change_audio_profile_failed',
          severity: 'error', details: {'error': e.toString()});
    }
  }

  /// Called when record profile setting changes.
  Future<void> onRecordProfileSettingChanged() async {
    await _resetState();
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  void dispose() {
    autoSaveMessage.dispose();
  }
}

/// Parameters for a websocket reconnect attempt.
class _ReconnectParams {
  final BleAudioCodec codec;
  final int? sampleRate;
  final String? source;

  _ReconnectParams({
    required this.codec,
    this.sampleRate,
    this.source,
  });
}
