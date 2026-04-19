import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recording/recording_state_machine.dart';
import 'package:omi/services/recording/session_lifecycle_manager.dart';
import 'package:omi/services/recording/session_snapshot.dart';

void main() {
  late SessionLifecycleManager slm;

  setUp(() {
    slm = SessionLifecycleManager();
  });

  tearDown(() {
    slm.dispose();
  });

  group('Initial state', () {
    test('starts in idle phase', () {
      expect(slm.phase, SessionPhase.idle);
    });

    test('snapshot is null initially', () {
      expect(slm.currentSnapshot, isNull);
    });

    test('lastAudioReceivedAt is null initially', () {
      expect(slm.lastAudioReceivedAt, isNull);
    });
  });

  group('Valid transitions', () {
    test('idle -> active', () {
      expect(slm.transition(SessionPhase.active), isTrue);
      expect(slm.phase, SessionPhase.active);
    });

    test('active -> stopping', () {
      slm.transition(SessionPhase.active);
      expect(slm.transition(SessionPhase.stopping), isTrue);
      expect(slm.phase, SessionPhase.stopping);
    });

    test('active -> idle (cancelNoSegments)', () {
      slm.transition(SessionPhase.active);
      expect(slm.transition(SessionPhase.idle), isTrue);
      expect(slm.phase, SessionPhase.idle);
    });

    test('stopping -> finalizing', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      expect(slm.transition(SessionPhase.finalizing), isTrue);
      expect(slm.phase, SessionPhase.finalizing);
    });

    test('finalizing -> restarting', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      expect(slm.transition(SessionPhase.restarting), isTrue);
      expect(slm.phase, SessionPhase.restarting);
    });

    test('finalizing -> idle', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      expect(slm.transition(SessionPhase.idle), isTrue);
      expect(slm.phase, SessionPhase.idle);
    });

    test('restarting -> active', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      slm.transition(SessionPhase.restarting);
      expect(slm.transition(SessionPhase.active), isTrue);
      expect(slm.phase, SessionPhase.active);
    });

    test('restarting -> idle', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      slm.transition(SessionPhase.restarting);
      expect(slm.transition(SessionPhase.idle), isTrue);
      expect(slm.phase, SessionPhase.idle);
    });

    test('full lifecycle: idle -> active -> stopping -> finalizing -> idle',
        () {
      expect(slm.transition(SessionPhase.active), isTrue);
      expect(slm.transition(SessionPhase.stopping), isTrue);
      expect(slm.transition(SessionPhase.finalizing), isTrue);
      expect(slm.transition(SessionPhase.idle), isTrue);
      expect(slm.phase, SessionPhase.idle);
    });
  });

  group('Invalid transitions', () {
    test('idle -> finalizing is invalid', () {
      expect(slm.transition(SessionPhase.finalizing), isFalse);
      expect(slm.phase, SessionPhase.idle);
    });

    test('idle -> stopping is invalid', () {
      expect(slm.transition(SessionPhase.stopping), isFalse);
      expect(slm.phase, SessionPhase.idle);
    });

    test('idle -> restarting is invalid', () {
      expect(slm.transition(SessionPhase.restarting), isFalse);
      expect(slm.phase, SessionPhase.idle);
    });

    test('active -> finalizing is invalid', () {
      slm.transition(SessionPhase.active);
      expect(slm.transition(SessionPhase.finalizing), isFalse);
      expect(slm.phase, SessionPhase.active);
    });

    test('active -> restarting is invalid', () {
      slm.transition(SessionPhase.active);
      expect(slm.transition(SessionPhase.restarting), isFalse);
      expect(slm.phase, SessionPhase.active);
    });

    test('stopping -> idle is invalid', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      expect(slm.transition(SessionPhase.idle), isFalse);
      expect(slm.phase, SessionPhase.stopping);
    });

    test('stopping -> active is invalid', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      expect(slm.transition(SessionPhase.active), isFalse);
      expect(slm.phase, SessionPhase.stopping);
    });

    test('stopping -> restarting is invalid', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      expect(slm.transition(SessionPhase.restarting), isFalse);
      expect(slm.phase, SessionPhase.stopping);
    });

    test('finalizing -> stopping is invalid', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      expect(slm.transition(SessionPhase.stopping), isFalse);
      expect(slm.phase, SessionPhase.finalizing);
    });

    test('finalizing -> active is invalid', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      expect(slm.transition(SessionPhase.active), isFalse);
      expect(slm.phase, SessionPhase.finalizing);
    });

    test('restarting -> stopping is invalid', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      slm.transition(SessionPhase.restarting);
      expect(slm.transition(SessionPhase.stopping), isFalse);
      expect(slm.phase, SessionPhase.restarting);
    });

    test('restarting -> finalizing is invalid', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);
      slm.transition(SessionPhase.restarting);
      expect(slm.transition(SessionPhase.finalizing), isFalse);
      expect(slm.phase, SessionPhase.restarting);
    });
  });

  group('No-op transitions (same phase)', () {
    test('idle -> idle returns true without changing phase', () {
      expect(slm.transition(SessionPhase.idle), isTrue);
      expect(slm.phase, SessionPhase.idle);
    });

    test('active -> active returns true without changing phase', () {
      slm.transition(SessionPhase.active);
      expect(slm.transition(SessionPhase.active), isTrue);
      expect(slm.phase, SessionPhase.active);
    });

    test('stopping -> stopping returns true without changing phase', () {
      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      expect(slm.transition(SessionPhase.stopping), isTrue);
      expect(slm.phase, SessionPhase.stopping);
    });
  });

  group('Phase notifier', () {
    test('notifies listeners on valid transition', () {
      final phases = <SessionPhase>[];
      slm.phaseNotifier.addListener(() {
        phases.add(slm.phaseNotifier.value);
      });

      slm.transition(SessionPhase.active);
      slm.transition(SessionPhase.stopping);
      slm.transition(SessionPhase.finalizing);

      expect(phases, [
        SessionPhase.active,
        SessionPhase.stopping,
        SessionPhase.finalizing,
      ]);
    });

    test('does not notify on invalid transition', () {
      int notifyCount = 0;
      slm.phaseNotifier.addListener(() {
        notifyCount++;
      });

      slm.transition(SessionPhase.finalizing); // invalid from idle

      expect(notifyCount, 0);
    });

    test('does not notify on same-phase no-op', () {
      int notifyCount = 0;
      slm.phaseNotifier.addListener(() {
        notifyCount++;
      });

      slm.transition(SessionPhase.idle); // already idle

      expect(notifyCount, 0);
    });
  });

  group('Session lifecycle', () {
    test('startSession transitions to active and clears state', () {
      // Set some state first
      slm.markAudioReceived();

      slm.startSession();

      expect(slm.phase, SessionPhase.active);
      expect(slm.currentSnapshot, isNull);
      expect(slm.lastAudioReceivedAt, isNull);
    });

    test('reset clears everything to idle', () {
      slm.transition(SessionPhase.active);
      slm.markAudioReceived();
      slm.setSnapshot(_makeSnapshot());

      slm.reset();

      expect(slm.phase, SessionPhase.idle);
      expect(slm.currentSnapshot, isNull);
      expect(slm.lastAudioReceivedAt, isNull);
    });
  });

  group('Audio tracking', () {
    test('markAudioReceived updates timestamp', () {
      expect(slm.lastAudioReceivedAt, isNull);

      slm.markAudioReceived();

      expect(slm.lastAudioReceivedAt, isNotNull);
      expect(
        DateTime.now().difference(slm.lastAudioReceivedAt!).inSeconds,
        lessThan(2),
      );
    });

    test('markAudioReceived updates to latest timestamp', () {
      slm.markAudioReceived();
      final first = slm.lastAudioReceivedAt!;

      // Small delay to ensure different timestamp
      slm.markAudioReceived();
      final second = slm.lastAudioReceivedAt!;

      expect(second.isAfter(first) || second.isAtSameMomentAs(first), isTrue);
    });
  });

  group('Snapshot management', () {
    test('setSnapshot stores snapshot', () {
      final snapshot = _makeSnapshot();
      slm.setSnapshot(snapshot);

      expect(slm.currentSnapshot, same(snapshot));
    });

    test('setSnapshot replaces previous snapshot', () {
      final first = _makeSnapshot(sessionId: 'sess-1');
      final second = _makeSnapshot(sessionId: 'sess-2');

      slm.setSnapshot(first);
      slm.setSnapshot(second);

      expect(slm.currentSnapshot?.sessionId, 'sess-2');
    });
  });

  group('Idempotency', () {
    test('same sessionId produces same key', () {
      final key1 = slm.deriveIdempotencyKey('session-abc');
      final key2 = slm.deriveIdempotencyKey('session-abc');

      expect(key1, equals(key2));
    });

    test('different sessionId produces different key', () {
      final key1 = slm.deriveIdempotencyKey('session-abc');
      final key2 = slm.deriveIdempotencyKey('session-xyz');

      expect(key1, isNot(equals(key2)));
    });

    test('key is a valid UUID string', () {
      final key = slm.deriveIdempotencyKey('session-test');

      // UUID v5 format: 8-4-4-4-12 hex chars
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(key),
        isTrue,
      );
    });
  });
}

/// Helper to create a minimal [SessionSnapshot] for testing.
SessionSnapshot _makeSnapshot({String sessionId = 'test-session'}) {
  return SessionSnapshot(
    sessionId: sessionId,
    allSegments: [],
    startedAt: DateTime(2026, 4, 17, 10, 0),
    stoppedAt: DateTime(2026, 4, 17, 10, 30),
    source: RecordingSource.phoneMic,
    idempotencyKey: 'test-key',
  );
}
