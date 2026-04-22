import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/transcript_segment.dart';

void main() {
  group('mergeConsecutiveSegmentsByTime', () {
    test('merges when resulting duration stays within default cap', () {
      final segments = [
        _seg('a', text: 'Hola', start: 0, end: 20),
        _seg('b', text: 'mundo', start: 20.1, end: 40),
      ];

      TranscriptSegment.mergeConsecutiveSegmentsByTime(segments);

      expect(segments.length, 1);
      expect(segments.first.text, 'Hola mundo');
      expect(segments.first.end, 40);
    });

    test('rejects merge when resulting duration exceeds default cap', () {
      final segments = [
        _seg('a', text: 'Primero', start: 0, end: 40),
        _seg('b', text: 'Segundo', start: 40.1, end: 70),
      ];

      TranscriptSegment.mergeConsecutiveSegmentsByTime(segments);

      expect(segments.length, 2, reason: 'mergedDuration 70s > 60s cap');
      expect(segments[0].text, 'Primero');
      expect(segments[1].text, 'Segundo');
    });

    test('allows merge when resulting duration equals the cap (inclusive)', () {
      final segments = [
        _seg('a', text: 'A', start: 0, end: 30),
        _seg('b', text: 'B', start: 30, end: 60),
      ];

      TranscriptSegment.mergeConsecutiveSegmentsByTime(segments);

      expect(segments.length, 1);
      expect(segments.first.end, 60);
    });

    test('honors custom cap override', () {
      final segments = [
        _seg('a', text: 'uno', start: 0, end: 45),
        _seg('b', text: 'dos', start: 45.1, end: 90),
      ];

      TranscriptSegment.mergeConsecutiveSegmentsByTime(
        segments,
        maxMergedDurationSeconds: 120.0,
      );

      expect(segments.length, 1, reason: 'custom cap 120s permits 90s merge');
      expect(segments.first.text, 'uno dos');
    });

    test('does not merge across different speakers regardless of cap', () {
      final segments = [
        _seg('a', text: 'user', speaker: 'SPEAKER_00', start: 0, end: 10),
        _seg('b', text: 'other', speaker: 'SPEAKER_01', start: 10.1, end: 20),
      ];

      TranscriptSegment.mergeConsecutiveSegmentsByTime(segments);

      expect(segments.length, 2);
    });
  });

  group('mergeNewSegmentsAtBoundary', () {
    test('rejects boundary merge when resulting duration exceeds cap', () {
      final segments = [
        _seg('a', text: 'previo', start: 0, end: 40),
        _seg('b', text: 'nuevo', start: 40.1, end: 70),
      ];

      TranscriptSegment.mergeNewSegmentsAtBoundary(
        segments,
        insertStartIndex: 1,
      );

      expect(segments.length, 2, reason: 'cap blocks 70s merge');
      expect(segments[0].text, 'previo');
      expect(segments[1].text, 'nuevo');
    });

    test('merges boundary when under cap', () {
      final segments = [
        _seg('a', text: 'hola', start: 0, end: 20),
        _seg('b', text: 'que tal', start: 20.1, end: 40),
      ];

      TranscriptSegment.mergeNewSegmentsAtBoundary(
        segments,
        insertStartIndex: 1,
      );

      expect(segments.length, 1);
      expect(segments.first.text, 'hola que tal');
    });
  });
}

TranscriptSegment _seg(
  String id, {
  required String text,
  required double start,
  required double end,
  String speaker = 'SPEAKER_00',
  bool isUser = false,
}) {
  return TranscriptSegment(
    id: id,
    text: text,
    speaker: speaker,
    isUser: isUser,
    personId: null,
    start: start,
    end: end,
    translations: [],
  );
}
