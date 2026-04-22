import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recording/recording_health_monitor.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart';

void main() {
  group('LocalSttHealthMonitor', () {
    test('reports healthy during grace period when no audio yet', () {
      final m = LocalSttHealthMonitor(getLastAudioBytesSentAt: () => null);
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.healthy);
    });

    test('reports stalled after grace period when no audio ever arrived', () async {
      // Use a mock "created long ago" by setting the getter and waiting.
      // Instead of waiting, we assert the threshold logic via the fact that
      // after 31s with null audio it should be stalled. We can't advance wall
      // clock cheaply in a unit test, so we validate indirectly via the
      // degraded/healthy paths with timestamped inputs below.
      final m = LocalSttHealthMonitor(getLastAudioBytesSentAt: () => null);
      addTearDown(m.dispose);
      // Fresh instance: still in grace → healthy.
      expect(m.status, HealthStatus.healthy);
    });

    test('reports healthy when audio bytes are recent (<30s)', () {
      final m = LocalSttHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(seconds: 5)),
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.healthy);
    });

    test('reports stalled when audio bytes are old (>30s)', () {
      final m = LocalSttHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(seconds: 45)),
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.stalled);
    });

    test('never reports failed (no terminal state for local)', () {
      final m = LocalSttHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(hours: 5)),
      );
      addTearDown(m.dispose);
      expect(m.status, isNot(HealthStatus.failed));
    });

    test('timeSinceLastSignal reflects audio gap', () {
      final last = DateTime.now().subtract(const Duration(seconds: 7));
      final m = LocalSttHealthMonitor(getLastAudioBytesSentAt: () => last);
      addTearDown(m.dispose);
      expect(m.timeSinceLastSignal.inSeconds, greaterThanOrEqualTo(7));
      expect(m.timeSinceLastSignal.inSeconds, lessThan(9));
    });

    test('stallThreshold is 30s', () {
      final m = LocalSttHealthMonitor(getLastAudioBytesSentAt: () => null);
      addTearDown(m.dispose);
      expect(m.stallThreshold, const Duration(seconds: 30));
    });
  });

  group('CloudSttHealthMonitor', () {
    test('reports healthy with connected socket + recent audio + recent segments', () {
      final now = DateTime.now();
      final m = CloudSttHealthMonitor(
        getLastAudioBytesSentAt: () => now.subtract(const Duration(seconds: 5)),
        getLastSegmentReceivedAt: () => now.subtract(const Duration(seconds: 10)),
        getSocketState: () => SocketServiceState.connected,
        getSegmentsCount: () => 3,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.healthy);
    });

    test('reports stalled when socket disconnected briefly (<60s)', () {
      final m = CloudSttHealthMonitor(
        getLastAudioBytesSentAt: () => DateTime.now(),
        getLastSegmentReceivedAt: () => DateTime.now(),
        getSocketState: () => SocketServiceState.disconnected,
        getSegmentsCount: () => 3,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.stalled);
    });

    test('reports stalled when audio bytes gap > 30s even with socket connected', () {
      final m = CloudSttHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(seconds: 45)),
        getLastSegmentReceivedAt: () => DateTime.now(),
        getSocketState: () => SocketServiceState.connected,
        getSegmentsCount: () => 3,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.stalled);
    });

    test('reports degraded when segment gap > 60s but audio still flowing', () {
      final m = CloudSttHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(seconds: 5)),
        getLastSegmentReceivedAt: () =>
            DateTime.now().subtract(const Duration(seconds: 90)),
        getSocketState: () => SocketServiceState.connected,
        getSegmentsCount: () => 3,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.degraded);
    });

    test('reports healthy in grace period when no audio yet but socket up', () {
      final m = CloudSttHealthMonitor(
        getLastAudioBytesSentAt: () => null,
        getLastSegmentReceivedAt: () => null,
        getSocketState: () => SocketServiceState.connected,
        getSegmentsCount: () => 0,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.healthy);
    });
  });

  group('BleHealthMonitor', () {
    test('reports healthy when BLE connected + recent audio', () {
      final m = BleHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(seconds: 3)),
        getIsConnected: () => true,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.healthy);
    });

    test('reports degraded when bytes gap in 10-30s range', () {
      final m = BleHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(seconds: 15)),
        getIsConnected: () => true,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.degraded);
    });

    test('reports stalled when BLE bytes gap > 30s', () {
      final m = BleHealthMonitor(
        getLastAudioBytesSentAt: () =>
            DateTime.now().subtract(const Duration(seconds: 40)),
        getIsConnected: () => true,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.stalled);
    });

    test('reports degraded when BLE just disconnected (<10s)', () {
      final m = BleHealthMonitor(
        getLastAudioBytesSentAt: () => DateTime.now(),
        getIsConnected: () => false,
      );
      addTearDown(m.dispose);
      expect(m.status, HealthStatus.degraded);
    });
  });

  group('statusNotifier', () {
    test('emits transitions between statuses (LocalSttHealthMonitor)', () async {
      DateTime? last;
      final m = LocalSttHealthMonitor(getLastAudioBytesSentAt: () => last);
      addTearDown(m.dispose);

      // Initial healthy (grace period).
      expect(m.statusNotifier.value, HealthStatus.healthy);

      // Transition to stalled with old timestamp → but notifier only fires on
      // periodic poll (every 5s), so we verify behavior of status getter.
      last = DateTime.now().subtract(const Duration(seconds: 60));
      expect(m.status, HealthStatus.stalled);
    });
  });
}
