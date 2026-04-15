import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/stt/cloud/cloud_stt_orchestrator.dart';

/// Unit tests for [CloudSttOrchestrator] that don't spin up a real socket
/// or timers. We exercise the deterministic bookkeeping: timestamp offset,
/// reconnect buffer, WAL flag, and health counters.
///
/// The socket lifecycle (connect, disconnect, sendAudio) and timer-based
/// paths (keep-alive, token refresh, health monitor) are covered by the
/// manual QA matrix described in the extraction plan — they require a live
/// WebSocket and are not meaningful as unit tests.
void main() {
  CloudSttOrchestrator makeOrchestrator() {
    return CloudSttOrchestrator(
      captureLog: CaptureLogService.instance,
      onRawMessage: (_) {},
      onSocketConnected: () {},
      onSocketClosed: (_) {},
      onSocketError: (_, __) {},
      onTranscriptionStalled: () {},
      onAutoFinalize: () async {},
      onMessageEventReceived: (_) {},
      onNotifyListeners: () {},
    );
  }

  group('timestamp offset', () {
    test('is zero by default', () {
      final orch = makeOrchestrator();
      expect(orch.cumulativeOffset, Duration.zero);
      expect(orch.recordingStartTime, isNull);
    });

    test('markRecordingStartIfNeeded sets start only once', () {
      final orch = makeOrchestrator();
      orch.markRecordingStartIfNeeded();
      final first = orch.recordingStartTime!;
      orch.markRecordingStartIfNeeded();
      expect(orch.recordingStartTime, first,
          reason: 'second call must be a no-op');
    });

    test('resetTimestampOffset clears both fields', () {
      final orch = makeOrchestrator();
      orch.markRecordingStartIfNeeded();
      orch.resetTimestampOffset();
      expect(orch.cumulativeOffset, Duration.zero);
      expect(orch.recordingStartTime, isNull);
    });
  });

  group('reconnect buffer', () {
    test('bufferAudioFrame accumulates bytes and drains in order', () {
      final orch = makeOrchestrator();
      orch.setBufferingForReconnect(true);

      orch.bufferAudioFrame([1, 2, 3]);
      orch.bufferAudioFrame([4, 5]);

      final drained = orch.drainReconnectBuffer();
      expect(drained, [
        [1, 2, 3],
        [4, 5],
      ]);
      expect(orch.drainReconnectBuffer(), isEmpty,
          reason: 'second drain returns empty; buffer was cleared');
    });

    test('buffer caps at 160 KB by dropping oldest', () {
      final orch = makeOrchestrator();
      orch.setBufferingForReconnect(true);

      // Fill beyond 160 KB: 4 x 50 KB = 200 KB → oldest must be dropped.
      final chunk = List<int>.filled(50 * 1024, 0);
      for (var i = 0; i < 4; i++) {
        orch.bufferAudioFrame(chunk);
      }
      final drained = orch.drainReconnectBuffer();
      final totalBytes = drained.fold<int>(0, (s, c) => s + c.length);
      expect(totalBytes, lessThanOrEqualTo(160000));
      expect(drained.length, lessThanOrEqualTo(3));
    });

    test('clearReconnectBuffer drops pending frames and disables buffering',
        () {
      final orch = makeOrchestrator();
      orch.setBufferingForReconnect(true);
      orch.bufferAudioFrame([1, 2, 3]);
      orch.clearReconnectBuffer();
      expect(orch.isBufferingForReconnect, isFalse);
      expect(orch.drainReconnectBuffer(), isEmpty);
    });
  });

  group('WAL flag', () {
    test('is off by default', () {
      expect(makeOrchestrator().walEnabled, isFalse);
    });

    test('setWalEnabled flips the flag', () {
      final orch = makeOrchestrator();
      orch.setWalEnabled(true);
      expect(orch.walEnabled, isTrue);
      orch.setWalEnabled(false);
      expect(orch.walEnabled, isFalse);
    });
  });

  group('health counters', () {
    test('markSegmentReceived updates timestamp and resets reconnects', () {
      final orch = makeOrchestrator();
      orch.incrementSttReconnectAttempts();
      orch.incrementSttReconnectAttempts();
      expect(orch.sttReconnectAttempts, 2);
      expect(orch.lastSegmentReceivedAt, isNull);

      orch.markSegmentReceived();

      expect(orch.sttReconnectAttempts, 0);
      expect(orch.lastSegmentReceivedAt, isNotNull);
    });

    test('incrementSttReconnectAttempts returns the new count', () {
      final orch = makeOrchestrator();
      expect(orch.incrementSttReconnectAttempts(), 1);
      expect(orch.incrementSttReconnectAttempts(), 2);
      expect(orch.sttReconnectAttempts, 2);
    });

    test('clearLastSegmentReceivedAt nulls just the stamp', () {
      final orch = makeOrchestrator();
      orch.markSegmentReceived();
      orch.incrementSttReconnectAttempts();

      orch.clearLastSegmentReceivedAt();

      expect(orch.lastSegmentReceivedAt, isNull);
      expect(orch.sttReconnectAttempts, 1,
          reason: 'reconnect counter must NOT be cleared');
    });

    test('resetHealth zeroes everything', () {
      final orch = makeOrchestrator();
      orch.markSegmentReceived();
      orch.updateLastAudioBytesSentAt();
      orch.incrementSttReconnectAttempts();

      orch.resetHealth();

      expect(orch.lastSegmentReceivedAt, isNull);
      expect(orch.sttReconnectAttempts, 0);
      expect(orch.lastAudioBytesSentAt, isNull);
    });
  });

  group('dispose', () {
    test('resets every field', () async {
      final orch = makeOrchestrator();
      orch.setWalEnabled(true);
      orch.markRecordingStartIfNeeded();
      orch.setBufferingForReconnect(true);
      orch.bufferAudioFrame([1, 2]);
      orch.markSegmentReceived();
      orch.updateLastAudioBytesSentAt();

      await orch.dispose();

      expect(orch.walEnabled, isFalse);
      expect(orch.cumulativeOffset, Duration.zero);
      expect(orch.recordingStartTime, isNull);
      expect(orch.isBufferingForReconnect, isFalse);
      expect(orch.drainReconnectBuffer(), isEmpty);
      expect(orch.lastSegmentReceivedAt, isNull);
      expect(orch.sttReconnectAttempts, 0);
      expect(orch.lastAudioBytesSentAt, isNull);
    });
  });
}
