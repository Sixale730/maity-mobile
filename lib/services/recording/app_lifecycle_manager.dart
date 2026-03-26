import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/sockets/transcription_service.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/platform/platform_service.dart';

/// Delegate interface for lifecycle events that need coordination with other services.
/// Implemented by CaptureProvider (slim) to avoid circular dependencies.
abstract class AppLifecycleDelegate {
  RecordingState get recordingState;
  bool get isPaused;
  bool get shouldAutoResumeAfterWake;
  bool get conversationFinalized;
  BtDevice? get recordingDevice;
  List<TranscriptSegment> get currentSegments;
  bool get isSpeechProfileMode;
  SocketServiceState? get socketState;
  int get recordingDuration;

  // Actions
  Future<void> stopHealthMonitor();
  void cancelKeepAlive();
  void cancelSilenceTimer();
  void resetSilenceTimer();
  void startMetricsTracking();
  Future<void> startHealthMonitor();
  Future<void> reconnectSocket();
  void startKeepAlive();
  Future<void> saveRecoveryData({bool synchronous = false});
  Future<void> stopMicService();
  Future<void> stopMicServiceCompletely();
  Future<void> stopSocket(String reason);
  Future<void> autoFinalizeOnConnectionLost();
  Future<void> streamSystemAudioRecording();
  void updateRecordingState(RecordingState state);
  void notifyListenersCallback();
}

/// Manages app lifecycle states (paused/resumed/detached).
/// Coordinates service pause/resume and background finalize timer.
class AppLifecycleManager with WidgetsBindingObserver {
  AppLifecycleDelegate? _delegate;

  // Background finalize timer
  Timer? _backgroundFinalizeTimer;

  // Background state flag
  bool _isAppInBackground = false;
  bool get isAppInBackground => _isAppInBackground;

  // Reconnection flags
  bool _isReconnectingAfterResume = false;
  bool get isReconnectingAfterResume => _isReconnectingAfterResume;

  bool _isReconnectingSocket = false;
  bool get isReconnectingSocket => _isReconnectingSocket;

  // Desktop method channels
  MethodChannel? _screenCaptureChannel;
  MethodChannel? _controlBarChannel;

  CaptureLogService get _captureLog => CaptureLogService.instance;

  /// Initialize the lifecycle manager and register as observer.
  void initialize({
    required AppLifecycleDelegate delegate,
    MethodChannel? screenCaptureChannel,
    MethodChannel? controlBarChannel,
  }) {
    _delegate = delegate;
    _screenCaptureChannel = screenCaptureChannel;
    _controlBarChannel = controlBarChannel;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    final delegate = _delegate;
    if (delegate == null) return;

    DebugLogManager.logEvent('app_lifecycle_changed', {
      'state': state.name,
      'recording_state': delegate.recordingState.name,
      'has_device': delegate.recordingDevice != null,
      'socket_state': delegate.socketState?.name ?? 'null',
      'is_paused': delegate.isPaused,
      'segment_count': delegate.currentSegments.length,
      'platform': PlatformService.isDesktop ? 'desktop' : 'mobile',
    });

    switch (state) {
      case AppLifecycleState.paused:
        _handleAppPaused();
        break;
      case AppLifecycleState.resumed:
        _handleAppResumed().catchError((e) {
          debugPrint('[AppLifecycleManager] Error in _handleAppResumed: $e');
        });
        break;
      case AppLifecycleState.detached:
        _handleAppDetached();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        debugPrint('[AppLifecycleManager] Lifecycle: $state');
        break;
    }
  }

  /// Handle app going to background (screen locked, app minimized).
  void _handleAppPaused() {
    final delegate = _delegate;
    if (delegate == null) return;

    _isAppInBackground = true;

    DebugLogManager.logEvent('app_paused_handling', {
      'action': 'stopping_background_services',
      'socket_state': delegate.socketState?.name ?? 'null',
      'recording_state': delegate.recordingState.name,
      'segment_count': delegate.currentSegments.length,
    });

    debugPrint('[AppLifecycleManager] App paused - stopping health monitor and keep-alive');

    // Stop health monitor to avoid reconnections while in background
    delegate.stopHealthMonitor();

    // Cancel keep-alive timer to prevent reconnection attempts in background
    delegate.cancelKeepAlive();

    // Cancel silence timer to prevent auto-finalize while in background
    // (it will restart naturally when new segments arrive after resume)
    delegate.cancelSilenceTimer();

    // Start background finalize timer: if socket stays dead for 3 min, auto-finalize
    final isRecording = delegate.recordingState == RecordingState.record ||
        delegate.recordingState == RecordingState.deviceRecord ||
        delegate.recordingState == RecordingState.systemAudioRecord;
    if (isRecording && delegate.currentSegments.isNotEmpty) {
      _startBackgroundFinalizeTimer();
    }

    // Save recovery data immediately to prevent data loss (synchronous: app may be killed)
    if (delegate.currentSegments.isNotEmpty && !delegate.isSpeechProfileMode) {
      debugPrint('[AppLifecycleManager] Saving recovery data before pause');
      delegate.saveRecoveryData(synchronous: true);
    }

    // Update foreground notification to reflect background state
    final isRecordingForNotification = delegate.recordingState == RecordingState.record ||
        delegate.recordingState == RecordingState.deviceRecord ||
        delegate.recordingState == RecordingState.systemAudioRecord;
    if (isRecordingForNotification) {
      updateForegroundNotification('recording');
    }
  }

  /// Handle app being terminated.
  void _handleAppDetached() {
    final delegate = _delegate;
    if (delegate == null) return;

    DebugLogManager.logEvent('app_detached_handling', {
      'action': 'cleanup',
      'recording_state': delegate.recordingState.name,
      'segment_count': delegate.currentSegments.length,
    });

    debugPrint('[AppLifecycleManager] App detached - performing cleanup');

    // FIRST: Stop background service mic completely BEFORE saving recovery data
    // to prevent FlutterJNI spam from the service sending audio to a dying engine.
    if (delegate.recordingState == RecordingState.record) {
      try {
        delegate.stopMicServiceCompletely();
      } catch (e) {
        debugPrint('[AppLifecycleManager] Error stopping mic service on detach: $e');
      }
    }

    // THEN: Save recovery data — segments are already in memory,
    // stopping the mic first doesn't lose any data
    if (delegate.currentSegments.isNotEmpty && !delegate.isSpeechProfileMode) {
      debugPrint('[AppLifecycleManager] Saving recovery data before detach');
      delegate.saveRecoveryData(synchronous: true);
    }

    // Stop socket cleanly
    delegate.stopSocket('app detached');

    // Update foreground notification before app dies
    updateForegroundNotification('waiting');
  }

  /// Handle app returning from background.
  Future<void> _handleAppResumed() async {
    final delegate = _delegate;
    if (delegate == null) return;

    _isAppInBackground = false;

    // Cancel background finalize timer since user is back
    _backgroundFinalizeTimer?.cancel();
    _backgroundFinalizeTimer = null;

    DebugLogManager.logEvent('app_resumed_handling_start', {
      'recording_state': delegate.recordingState.name,
      'socket_state': delegate.socketState?.name ?? 'null',
      'is_mobile': !PlatformService.isDesktop,
      'has_device': delegate.recordingDevice != null,
      'segment_count': delegate.currentSegments.length,
    });

    debugPrint('[AppLifecycleManager] App resumed - checking state');

    // Desktop-specific auto-resume logic for system audio
    if (PlatformService.isDesktop && delegate.shouldAutoResumeAfterWake) {
      try {
        final nativeRecording = await _screenCaptureChannel?.invokeMethod('isRecording') ?? false;

        if (!nativeRecording && delegate.recordingState != RecordingState.stop) {
          delegate.updateRecordingState(RecordingState.stop);
          await delegate.stopSocket('native recording stopped during sleep');
        }

        if (!nativeRecording && delegate.recordingState == RecordingState.stop) {
          await Future.delayed(const Duration(seconds: 2));
          await delegate.streamSystemAudioRecording();
        }
      } catch (e) {
        debugPrint('[AppLifecycleManager] Desktop resume error: $e');
      }
      return;
    }

    // Mobile: handle socket reconnection if we were recording
    final isRecording = delegate.recordingState == RecordingState.record ||
        delegate.recordingState == RecordingState.deviceRecord ||
        delegate.recordingState == RecordingState.systemAudioRecord;

    if (isRecording) {
      // Re-start metrics tracking that was paused in _handleAppPaused
      delegate.startMetricsTracking();

      // Cancel any running keep-alive before reconnecting to avoid cascading reconnections
      delegate.cancelKeepAlive();

      // Check if socket needs reconnection
      if (delegate.socketState != null && delegate.socketState != SocketServiceState.connected) {
        _isReconnectingSocket = true;
        delegate.notifyListenersCallback(); // UI shows "reconnecting" state immediately

        // Fire-and-forget: does NOT block the event loop
        _reconnectSocketAfterResumeAsync();
      } else {
        // Socket still connected, just restart health monitor
        delegate.startHealthMonitor();
        delegate.resetSilenceTimer();
      }
    }
  }

  /// Starts a timer that auto-finalizes the conversation if the socket
  /// remains disconnected while the app is in background for 3 minutes.
  void _startBackgroundFinalizeTimer() {
    final delegate = _delegate;
    if (delegate == null) return;

    _backgroundFinalizeTimer?.cancel();
    _backgroundFinalizeTimer = Timer(const Duration(minutes: 3), () {
      final d = _delegate;
      if (d == null) return;

      // If socket is still disconnected after 3 min in background, finalize
      if (d.socketState != SocketServiceState.connected &&
          d.currentSegments.isNotEmpty &&
          !d.conversationFinalized) {
        _captureLog.log('recording', 'background_auto_finalize', severity: 'warning', details: {
          'segments_count': d.currentSegments.length,
          'socket_state': d.socketState?.name ?? 'null',
          'minutes_in_background': 3,
        });
        debugPrint('[AppLifecycleManager] Background timer: socket dead for 3 min, auto-finalizing');
        d.autoFinalizeOnConnectionLost();

        // Update notification after background auto-finalize
        updateForegroundNotification('waiting');
      }
    });
  }

  /// Reconnect socket after app resumes from background.
  Future<void> _reconnectSocketAfterResume() async {
    final delegate = _delegate;
    if (delegate == null) return;

    DebugLogManager.logEvent('socket_reconnect_attempt', {
      'current_state': delegate.socketState?.name ?? 'null',
      'recording_state': delegate.recordingState.name,
    });

    debugPrint('[AppLifecycleManager] Attempting socket reconnect after resume');

    // Set flag to prevent onClosed() from triggering keep-alive during this stop
    _isReconnectingAfterResume = true;
    try {
      await delegate.reconnectSocket();

      DebugLogManager.logEvent('socket_reconnect_completed', {
        'new_state': delegate.socketState?.name ?? 'null',
      });
    } finally {
      _isReconnectingAfterResume = false;
    }
  }

  /// Non-blocking wrapper for socket reconnection after resume.
  void _reconnectSocketAfterResumeAsync() async {
    final delegate = _delegate;
    if (delegate == null) return;

    try {
      await _reconnectSocketAfterResume();

      if (delegate.socketState != SocketServiceState.connected) {
        debugPrint('[AppLifecycleManager] Immediate reconnect failed, starting keep-alive');
        delegate.startKeepAlive();
      }
    } catch (e, stack) {
      DebugLogManager.logEvent('app_resumed_reconnect_error', {
        'error': e.toString(),
        'stack': stack.toString().substring(0, min(500, stack.toString().length)),
      });
      debugPrint('[AppLifecycleManager] Resume reconnect error: $e');
      delegate.startKeepAlive();
    } finally {
      _isReconnectingSocket = false;
      delegate.startHealthMonitor(); // Start health monitor AFTER reconnection
      delegate.resetSilenceTimer();
      delegate.notifyListenersCallback();
    }
  }

  /// Updates the foreground service notification with the current state.
  /// States: 'waiting', 'device_connected', 'phone_mic', 'recording', 'processing', 'ready'
  void updateForegroundNotification(String state) {
    if (PlatformService.isDesktop) return;

    final lang = SharedPreferencesUtil().appLanguage;
    FlutterForegroundTask.sendDataToTask(jsonEncode({
      'type': 'notification',
      'state': state,
      'lang': lang,
    }));
    debugPrint('[ForegroundNotification] Sent state=$state, lang=$lang');
  }

  /// Determines the appropriate notification state based on current provider state.
  String getNotificationState() {
    final delegate = _delegate;
    if (delegate == null) return 'waiting';

    // Recording states take priority - but verify device exists for deviceRecord
    if (delegate.recordingState == RecordingState.record ||
        (delegate.recordingState == RecordingState.deviceRecord && delegate.recordingDevice != null) ||
        delegate.recordingState == RecordingState.systemAudioRecord) {
      return 'recording';
    }
    if (delegate.recordingState == RecordingState.initialising ||
        delegate.recordingState == RecordingState.processing) {
      return 'processing';
    }

    // Device connected but not recording
    if (delegate.recordingDevice != null) {
      return 'device_connected';
    }

    // Fallback to waiting
    return 'waiting';
  }

  /// Broadcast recording state to desktop control bar.
  void broadcastRecordingState() {
    if (!PlatformService.isDesktop) return;

    final delegate = _delegate;
    if (delegate == null) return;

    final stateData = {
      'isRecording': delegate.recordingState == RecordingState.systemAudioRecord ||
          delegate.recordingState == RecordingState.deviceRecord,
      'isPaused': delegate.isPaused,
      'duration': delegate.recordingDuration,
      'isInitialising': delegate.recordingState == RecordingState.initialising,
      'isProcessing': delegate.recordingState == RecordingState.processing,
    };

    _controlBarChannel?.invokeMethod('updateRecordingState', stateData);
  }

  /// Dispose of timers and remove lifecycle observer.
  void dispose() {
    _backgroundFinalizeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
