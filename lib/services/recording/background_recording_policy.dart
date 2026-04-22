import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/recording/recording_health_monitor.dart';
import 'package:omi/services/recording/session_lifecycle_manager.dart';

/// Decides when to auto-finalize an in-flight recording based on the app
/// lifecycle (foreground/background), recording health, and session state.
///
/// Pure policy: owns timers but no other side effects. The single output is
/// the [_onAutoFinalize] callback, which the owner (typically
/// [CaptureProvider]) wires to [RecordingController.autoFinalizeOnConnectionLost].
///
/// Rules:
///
/// | Scenario                                      | Behavior                        |
/// |-----------------------------------------------|---------------------------------|
/// | Active recording + background + healthy       | Keep recording, 30 min hard cap |
/// | Active recording + background + stalled/failed| Finalize on next check (30s)    |
/// | Paused + background                           | Finalize after 3 min grace      |
/// | Foreground before any timer fires             | Cancel all timers, no-op        |
/// | No segments yet                               | Skip entirely                   |
class BackgroundRecordingPolicy {
  BackgroundRecordingPolicy({
    required RecordingHealthMonitor? Function() getHealthMonitor,
    required bool Function() isPaused,
    required int Function() segmentsCount,
    required bool Function() conversationFinalized,
    required SessionPhase Function() sessionPhase,
    required VoidCallback onAutoFinalize,
    Duration pauseGracePeriod = const Duration(minutes: 3),
    Duration backgroundHardCap = const Duration(minutes: 30),
    Duration healthCheckInterval = const Duration(seconds: 30),
  })  : _getHealthMonitor = getHealthMonitor,
        _isPaused = isPaused,
        _segmentsCount = segmentsCount,
        _conversationFinalized = conversationFinalized,
        _sessionPhase = sessionPhase,
        _onAutoFinalize = onAutoFinalize,
        _pauseGracePeriod = pauseGracePeriod,
        _backgroundHardCap = backgroundHardCap,
        _healthCheckInterval = healthCheckInterval;

  final RecordingHealthMonitor? Function() _getHealthMonitor;
  final bool Function() _isPaused;
  final int Function() _segmentsCount;
  final bool Function() _conversationFinalized;
  final SessionPhase Function() _sessionPhase;
  final VoidCallback _onAutoFinalize;

  final Duration _pauseGracePeriod;
  final Duration _backgroundHardCap;
  final Duration _healthCheckInterval;

  Timer? _pauseFinalizeTimer;
  Timer? _hardCapTimer;
  Timer? _healthCheckTimer;

  CaptureLogService get _captureLog => CaptureLogService.instance;

  /// Called by the lifecycle owner when the app transitions into background.
  ///
  /// Starts one of two timer strategies depending on recording state:
  /// - If paused: grace-period timer (user likely forgot).
  /// - If actively recording: periodic health check + hard cap.
  ///
  /// Idempotent: calling multiple times cancels prior timers and restarts.
  void onAppBackgrounded() {
    _cancelAll();

    if (_segmentsCount() == 0) {
      // Nothing recorded yet — nothing to save. The watchdog / unexpected-stop
      // path in services.dart handles mic death before any segments exist.
      debugPrint('[BackgroundPolicy] Backgrounded with 0 segments, no-op');
      return;
    }

    if (_isPaused()) {
      debugPrint(
          '[BackgroundPolicy] Paused+background: grace timer ${_pauseGracePeriod.inMinutes} min');
      _captureLog.log('policy', 'bg_paused_grace_started', details: {
        'grace_minutes': _pauseGracePeriod.inMinutes,
      });
      _pauseFinalizeTimer = Timer(_pauseGracePeriod, () {
        _maybeFinalize(reason: 'paused_grace_expired');
      });
      return;
    }

    // Active recording in background.
    debugPrint(
        '[BackgroundPolicy] Active+background: health check every ${_healthCheckInterval.inSeconds}s, hard cap ${_backgroundHardCap.inMinutes} min');
    _captureLog.log('policy', 'bg_active_monitoring_started', details: {
      'health_check_seconds': _healthCheckInterval.inSeconds,
      'hard_cap_minutes': _backgroundHardCap.inMinutes,
    });
    _healthCheckTimer = Timer.periodic(_healthCheckInterval, (_) {
      final monitor = _getHealthMonitor();
      if (monitor == null) return;
      final s = monitor.status;
      if (s == HealthStatus.stalled || s == HealthStatus.failed) {
        debugPrint(
            '[BackgroundPolicy] Health=${s.name} in background, finalizing');
        _maybeFinalize(reason: 'health_${s.name}');
      }
    });
    _hardCapTimer = Timer(_backgroundHardCap, () {
      debugPrint(
          '[BackgroundPolicy] Hard cap ${_backgroundHardCap.inMinutes} min reached, finalizing');
      _maybeFinalize(reason: 'hard_cap_reached');
    });
  }

  /// Called when the app returns to foreground. Cancels pending timers so
  /// recording can continue without interruption.
  void onAppForegrounded() {
    if (_pauseFinalizeTimer != null ||
        _healthCheckTimer != null ||
        _hardCapTimer != null) {
      debugPrint('[BackgroundPolicy] Foregrounded, cancelling timers');
      _captureLog.log('policy', 'bg_timers_cancelled', severity: 'debug');
    }
    _cancelAll();
  }

  /// Release all timers. Call on session end or provider dispose.
  void dispose() {
    _cancelAll();
  }

  void _cancelAll() {
    _pauseFinalizeTimer?.cancel();
    _pauseFinalizeTimer = null;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _hardCapTimer?.cancel();
    _hardCapTimer = null;
  }

  void _maybeFinalize({required String reason}) {
    if (_segmentsCount() == 0 || _conversationFinalized()) {
      _cancelAll();
      return;
    }
    final phase = _sessionPhase();
    if (phase == SessionPhase.stopping || phase == SessionPhase.finalizing) {
      // Another path already handled finalization; don't double-trigger.
      _cancelAll();
      return;
    }
    _captureLog.log('policy', 'bg_auto_finalize_triggered', severity: 'warning', details: {
      'reason': reason,
      'segments_count': _segmentsCount(),
    });
    _cancelAll();
    _onAutoFinalize();
  }

  // ---------------------------------------------------------------------------
  // Test-only accessors
  // ---------------------------------------------------------------------------

  @visibleForTesting
  bool get hasActiveTimers =>
      _pauseFinalizeTimer != null ||
      _healthCheckTimer != null ||
      _hardCapTimer != null;

  @visibleForTesting
  bool get isInPausedGraceMode => _pauseFinalizeTimer != null;

  @visibleForTesting
  bool get isMonitoringActiveRecording =>
      _healthCheckTimer != null || _hardCapTimer != null;
}
