import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recording/background_recording_policy.dart';
import 'package:omi/services/recording/recording_health_monitor.dart';
import 'package:omi/services/recording/session_lifecycle_manager.dart';

/// Test-only fake monitor; returns whatever status we hand it.
class _FakeHealthMonitor implements RecordingHealthMonitor {
  _FakeHealthMonitor(this._status);
  HealthStatus _status;
  void setStatus(HealthStatus s) => _status = s;

  @override
  HealthStatus get status => _status;
  @override
  Duration get timeSinceLastSignal => Duration.zero;
  @override
  Duration get stallThreshold => const Duration(seconds: 30);
  @override
  ValueListenable<HealthStatus> get statusNotifier =>
      ValueNotifier(_status);
  @override
  void dispose() {}
}

void main() {
  // Short durations so tests don't actually wait 3 min / 30 min of wall clock.
  const tinyGrace = Duration(milliseconds: 50);
  const tinyHardCap = Duration(milliseconds: 200);
  const tinyCheck = Duration(milliseconds: 20);

  late _FakeHealthMonitor monitor;
  bool paused = false;
  int segs = 0;
  bool finalized = false;
  SessionPhase phase = SessionPhase.active;
  int finalizeCallCount = 0;

  BackgroundRecordingPolicy makePolicy() {
    return BackgroundRecordingPolicy(
      getHealthMonitor: () => monitor,
      isPaused: () => paused,
      segmentsCount: () => segs,
      conversationFinalized: () => finalized,
      sessionPhase: () => phase,
      onAutoFinalize: () => finalizeCallCount++,
      pauseGracePeriod: tinyGrace,
      backgroundHardCap: tinyHardCap,
      healthCheckInterval: tinyCheck,
    );
  }

  setUp(() {
    monitor = _FakeHealthMonitor(HealthStatus.healthy);
    paused = false;
    segs = 0;
    finalized = false;
    phase = SessionPhase.active;
    finalizeCallCount = 0;
  });

  group('onAppBackgrounded — guards', () {
    test('no-op when there are no segments yet', () async {
      final p = makePolicy();
      segs = 0;
      p.onAppBackgrounded();
      expect(p.hasActiveTimers, isFalse);
      await Future.delayed(tinyHardCap + const Duration(milliseconds: 10));
      expect(finalizeCallCount, 0);
      p.dispose();
    });

    test('cancels prior timers when called twice', () async {
      final p = makePolicy();
      segs = 2;
      p.onAppBackgrounded();
      expect(p.isMonitoringActiveRecording, isTrue);
      // Re-enter background, e.g. lifecycle churn — should re-arm, not double.
      p.onAppBackgrounded();
      expect(p.isMonitoringActiveRecording, isTrue);
      p.dispose();
    });
  });

  group('Active recording in background', () {
    test('keeps recording when health stays healthy (no finalize before hard cap)', () async {
      final p = makePolicy();
      segs = 2;
      monitor.setStatus(HealthStatus.healthy);
      p.onAppBackgrounded();
      // Wait past a few health checks but before hard cap.
      await Future.delayed(tinyCheck * 4);
      expect(finalizeCallCount, 0);
      p.dispose();
    });

    test('finalizes on first health-check tick when status=stalled', () async {
      final p = makePolicy();
      segs = 2;
      monitor.setStatus(HealthStatus.stalled);
      p.onAppBackgrounded();
      await Future.delayed(tinyCheck + const Duration(milliseconds: 15));
      expect(finalizeCallCount, 1);
      p.dispose();
    });

    test('finalizes on first health-check tick when status=failed', () async {
      final p = makePolicy();
      segs = 2;
      monitor.setStatus(HealthStatus.failed);
      p.onAppBackgrounded();
      await Future.delayed(tinyCheck + const Duration(milliseconds: 15));
      expect(finalizeCallCount, 1);
      p.dispose();
    });

    test('hard cap triggers finalize even when health stays healthy', () async {
      final p = makePolicy();
      segs = 2;
      monitor.setStatus(HealthStatus.healthy);
      p.onAppBackgrounded();
      await Future.delayed(tinyHardCap + const Duration(milliseconds: 30));
      expect(finalizeCallCount, 1);
      p.dispose();
    });
  });

  group('Pause + background', () {
    test('finalizes after grace period when paused', () async {
      final p = makePolicy();
      paused = true;
      segs = 2;
      p.onAppBackgrounded();
      expect(p.isInPausedGraceMode, isTrue);
      await Future.delayed(tinyGrace + const Duration(milliseconds: 15));
      expect(finalizeCallCount, 1);
      p.dispose();
    });

    test('onAppForegrounded cancels paused grace timer', () async {
      final p = makePolicy();
      paused = true;
      segs = 2;
      p.onAppBackgrounded();
      p.onAppForegrounded();
      expect(p.hasActiveTimers, isFalse);
      await Future.delayed(tinyGrace + const Duration(milliseconds: 20));
      expect(finalizeCallCount, 0);
      p.dispose();
    });
  });

  group('Foreground cancels all', () {
    test('cancels active recording timers on foreground', () async {
      final p = makePolicy();
      segs = 2;
      monitor.setStatus(HealthStatus.healthy);
      p.onAppBackgrounded();
      p.onAppForegrounded();
      expect(p.hasActiveTimers, isFalse);
      await Future.delayed(tinyHardCap + const Duration(milliseconds: 30));
      expect(finalizeCallCount, 0);
      p.dispose();
    });
  });

  group('Finalize guards', () {
    test('does not finalize if conversationFinalized is already true', () async {
      final p = makePolicy();
      segs = 2;
      finalized = true;
      monitor.setStatus(HealthStatus.stalled);
      p.onAppBackgrounded();
      await Future.delayed(tinyCheck + const Duration(milliseconds: 15));
      expect(finalizeCallCount, 0);
      p.dispose();
    });

    test('does not finalize if session already stopping/finalizing', () async {
      final p = makePolicy();
      segs = 2;
      phase = SessionPhase.stopping;
      monitor.setStatus(HealthStatus.stalled);
      p.onAppBackgrounded();
      await Future.delayed(tinyCheck + const Duration(milliseconds: 15));
      expect(finalizeCallCount, 0);

      phase = SessionPhase.finalizing;
      p.onAppBackgrounded();
      await Future.delayed(tinyCheck + const Duration(milliseconds: 15));
      expect(finalizeCallCount, 0);
      p.dispose();
    });

    test('does not double-finalize when multiple triggers fire', () async {
      final p = makePolicy();
      segs = 2;
      monitor.setStatus(HealthStatus.stalled);
      p.onAppBackgrounded();
      // First tick should finalize; subsequent ticks should not retrigger
      // because _cancelAll stops the timers.
      await Future.delayed(tinyCheck * 6);
      expect(finalizeCallCount, 1);
      p.dispose();
    });
  });

  group('Regression — the original bug', () {
    test('Local STT healthy in background for 10+ check intervals does NOT finalize early', () async {
      // This is the case the user hit: Local STT with audio flowing while in
      // background. The old timer (3 min) finalized based on "socket state
      // != connected", which for local STT is a permanent false positive.
      // The new policy looks at HealthStatus instead, so `healthy` is respected.
      final p = makePolicy();
      segs = 5;
      monitor.setStatus(HealthStatus.healthy);
      p.onAppBackgrounded();
      await Future.delayed(tinyCheck * 8);
      expect(finalizeCallCount, 0,
          reason: 'Healthy local STT in background must not finalize before hard cap');
      p.dispose();
    });
  });
}
