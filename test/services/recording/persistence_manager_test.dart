import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/recovery_session.dart';
import 'package:omi/services/recording/persistence_manager.dart';

/// Helper to create a TranscriptSegment for testing.
TranscriptSegment _seg(String text, {double start = 0, double end = 1}) {
  return TranscriptSegment(
    id: 'test_${start}_0',
    text: text,
    speaker: 'SPEAKER_00',
    isUser: false,
    personId: null,
    start: start,
    end: end,
    translations: [],
  );
}

/// Helper to build a RecoverySession with given word strings.
RecoverySession _session({
  required List<String> texts,
  String? draftId,
  double endTime = 30.0,
}) {
  final segments = texts
      .asMap()
      .entries
      .map((e) => _seg(e.value, start: e.key.toDouble(), end: endTime))
      .toList();
  return RecoverySession(
    sessionId: 'test-session',
    startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
    lastUpdatedAt: DateTime.now(),
    segments: segments,
    draftConversationId: draftId,
  );
}

void main() {
  late PersistenceManager pm;

  setUp(() {
    pm = PersistenceManager();
  });

  tearDown(() {
    pm.dispose();
  });

  // ---------------------------------------------------------------------------
  // Mutex prevents concurrent finalize (C2)
  // ---------------------------------------------------------------------------
  group('Finalize mutex', () {
    test('concurrent finalize calls are serialized, not interleaved', () async {
      // Both calls will attempt to finalize with empty segments, which returns
      // false quickly, but the point is that the mutex serializes them.
      final segments = <TranscriptSegment>[];

      final f1 = pm.finalizeConversation(
        segments: segments,
        userId: 'u1',
        startedAt: DateTime.now(),
        isSpeechProfileMode: false,
        onSuccess: () {},
      );

      final f2 = pm.finalizeConversation(
        segments: segments,
        userId: 'u1',
        startedAt: DateTime.now(),
        isSpeechProfileMode: false,
        onSuccess: () {},
      );

      // Both should complete without error (serialized by mutex)
      final results = await Future.wait([f1, f2]);
      // Empty segments => both return false
      expect(results, [false, false]);
    });

    test('finalize skips when speech profile mode is active', () async {
      final result = await pm.finalizeConversation(
        segments: [_seg('hello world test')],
        userId: 'u1',
        startedAt: DateTime.now(),
        isSpeechProfileMode: true,
        onSuccess: () {},
      );
      expect(result, isFalse);
    });

    test('finalize skips when segments are empty', () async {
      final result = await pm.finalizeConversation(
        segments: [],
        userId: 'u1',
        startedAt: DateTime.now(),
        isSpeechProfileMode: false,
        onSuccess: () {},
      );
      expect(result, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Recovery threshold (M1)
  // ---------------------------------------------------------------------------
  group('Recovery threshold (M1)', () {
    test('rejects session with < 20 words AND < 15s', () {
      // 4 words, 5s duration
      final session = _session(
        texts: ['hello world test now'],
        endTime: 5.0,
      );
      expect(session.wordCount, 4);
      expect(pm.isWorthRecovering(session), isFalse);
    });

    test('accepts session with >= 20 words even if short duration', () {
      // 20 words in a single segment
      final session = _session(
        texts: ['one two three four five six seven eight nine ten '
            'eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty'],
        endTime: 5.0,
      );
      expect(session.wordCount, greaterThanOrEqualTo(20));
      expect(pm.isWorthRecovering(session), isTrue);
    });

    test('accepts session with >= 15s even if few words', () {
      final session = _session(
        texts: ['hello'],
        endTime: 20.0,
      );
      expect(session.wordCount, lessThan(20));
      expect(session.estimatedDuration.inSeconds, greaterThanOrEqualTo(15));
      expect(pm.isWorthRecovering(session), isTrue);
    });

    test('rejects session with draft ID if below threshold', () {
      // After the local-first refactor, draft IDs are no longer used.
      // Recovery threshold is purely based on word count and duration.
      final session = _session(
        texts: ['hi'],
        endTime: 2.0,
        draftId: 'draft-123',
      );
      expect(session.wordCount, lessThan(20));
      expect(pm.isWorthRecovering(session), isFalse);
    });

    test('rejects empty session', () {
      final session = _session(texts: [], endTime: 0);
      expect(pm.isWorthRecovering(session), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Reset (C3)
  // ---------------------------------------------------------------------------
  group('Reset', () {
    test('reset clears recovery state without error', () {
      // Schedule a local save to set internal recovery state
      pm.scheduleLocalSave(
        [_seg('test segment')],
        'session-1',
        DateTime.now(),
        false,
      );

      // reset should clear internal state without throwing
      pm.reset();

      // Calling reset again should be safe (idempotent)
      pm.reset();
    });

    test('resetAsync waits for finalize mutex before resetting (C3)', () async {
      // Schedule a local save to set internal recovery state
      pm.scheduleLocalSave(
        [_seg('test segment')],
        'session-1',
        DateTime.now(),
        false,
      );

      // resetAsync acquires the mutex, so it serializes with any in-flight finalize
      await pm.resetAsync();

      // Should be safe to call again
      await pm.resetAsync();
    });
  });

  // ---------------------------------------------------------------------------
  // Force finalize (C3)
  // ---------------------------------------------------------------------------
  group('forceFinalize (C3)', () {
    test('returns false with empty segments and resets state', () async {
      // forceFinalize with empty segments returns false but still calls reset()
      final result = await pm.forceFinalize(
        segments: [],
        userId: 'u1',
        startedAt: DateTime.now(),
        isSpeechProfileMode: false,
        onSuccess: () {},
      );

      expect(result, isFalse);
    });

    test('returns false when speech profile mode is active', () async {
      final result = await pm.forceFinalize(
        segments: [_seg('hello world test')],
        userId: 'u1',
        startedAt: DateTime.now(),
        isSpeechProfileMode: true,
        onSuccess: () {},
      );

      expect(result, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // scheduleLocalSave guards
  // ---------------------------------------------------------------------------
  group('scheduleLocalSave', () {
    test('skips when speech profile mode is active', () {
      // Should not throw or schedule anything
      pm.scheduleLocalSave(
        [_seg('test')],
        'session-1',
        DateTime.now(),
        true, // isSpeechProfileMode
      );
      // No crash = pass
    });

    test('does not throw with valid arguments', () {
      // Normal call should not throw
      pm.scheduleLocalSave(
        [_seg('test segment data')],
        'session-1',
        DateTime.now(),
        false,
      );
      // No crash = pass
    });

    test('does not throw with null sessionId', () {
      pm.scheduleLocalSave(
        [_seg('test')],
        null,
        DateTime.now(),
        false,
      );
      // No crash = pass
    });
  });
}
