import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/recording/recording_state_machine.dart';
import 'package:omi/services/recording/session_snapshot.dart';

void main() {
  group('SessionSnapshot', () {
    test('totalWords counts words correctly', () {
      final snapshot = _makeSnapshot(segments: [
        _makeSegment('Hello world'),
        _makeSegment('This is a test'),
      ]);

      expect(snapshot.totalWords, 6);
    });

    test('totalWords handles empty text', () {
      final snapshot = _makeSnapshot(segments: [
        _makeSegment(''),
      ]);

      expect(snapshot.totalWords, 0);
    });

    test('totalWords handles extra whitespace', () {
      final snapshot = _makeSnapshot(segments: [
        _makeSegment('  hello   world  '),
      ]);

      expect(snapshot.totalWords, 2);
    });

    test('totalSegments returns correct count', () {
      final snapshot = _makeSnapshot(segments: [
        _makeSegment('a'),
        _makeSegment('b'),
        _makeSegment('c'),
      ]);

      expect(snapshot.totalSegments, 3);
    });

    test('duration calculates correctly', () {
      final snapshot = SessionSnapshot(
        sessionId: 'test',
        allSegments: [],
        startedAt: DateTime(2026, 4, 17, 10, 0),
        stoppedAt: DateTime(2026, 4, 17, 10, 30),
        source: RecordingSource.phoneMic,
        idempotencyKey: 'key',
      );

      expect(snapshot.duration, const Duration(minutes: 30));
    });

    test('transcriptText joins segments with newlines', () {
      final snapshot = _makeSnapshot(segments: [
        _makeSegment('Line one'),
        _makeSegment('Line two'),
      ]);

      expect(snapshot.transcriptText, 'Line one\nLine two');
    });

    test('transcriptText trims result', () {
      final snapshot = _makeSnapshot(segments: [
        _makeSegment('  Hello  '),
      ]);

      expect(snapshot.transcriptText, 'Hello');
    });

    test('isEmpty returns true when no segments', () {
      final snapshot = _makeSnapshot(segments: []);
      expect(snapshot.isEmpty, isTrue);
    });

    test('isEmpty returns false when segments exist', () {
      final snapshot = _makeSnapshot(segments: [_makeSegment('text')]);
      expect(snapshot.isEmpty, isFalse);
    });

    test('modifying original list does not affect snapshot', () {
      final segments = [_makeSegment('original')];
      final snapshot = SessionSnapshot(
        sessionId: 'test',
        allSegments: List.unmodifiable(segments),
        startedAt: DateTime(2026, 4, 17, 10, 0),
        stoppedAt: DateTime(2026, 4, 17, 10, 30),
        source: RecordingSource.phoneMic,
        idempotencyKey: 'key',
      );

      segments.add(_makeSegment('added'));

      expect(snapshot.totalSegments, 1);
      expect(snapshot.transcriptText, 'original');
    });
  });
}

SessionSnapshot _makeSnapshot({List<TranscriptSegment> segments = const []}) {
  return SessionSnapshot(
    sessionId: 'test-session',
    allSegments: segments,
    startedAt: DateTime(2026, 4, 17, 10, 0),
    stoppedAt: DateTime(2026, 4, 17, 10, 30),
    source: RecordingSource.phoneMic,
    idempotencyKey: 'test-key',
  );
}

TranscriptSegment _makeSegment(String text) {
  return TranscriptSegment(
    id: 'seg-${text.hashCode}',
    text: text,
    speaker: 'SPEAKER_00',
    isUser: false,
    personId: null,
    start: 0.0,
    end: 1.0,
    translations: [],
  );
}
