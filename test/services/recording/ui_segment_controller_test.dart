import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/recording/ui_segment_controller.dart';

void main() {
  group('collectAllSegments', () {
    test('returns active segments when no archives exist', () async {
      final controller = UISegmentController();
      controller.startSession('test-session', '.');

      controller.addSegments([
        _makeSegment('seg-1', 'Hello'),
        _makeSegment('seg-2', 'World'),
      ]);

      final all = await controller.collectAllSegments();

      expect(all.length, 2);
      expect(all[0].text, 'Hello');
      expect(all[1].text, 'World');

      controller.dispose();
    });

    test('returns empty list when no segments exist', () async {
      final controller = UISegmentController();
      controller.startSession('test-session', '.');

      final all = await controller.collectAllSegments();

      expect(all, isEmpty);

      controller.dispose();
    });
  });
}

TranscriptSegment _makeSegment(String id, String text) {
  return TranscriptSegment(
    id: id,
    text: text,
    speaker: 'SPEAKER_00',
    isUser: false,
    personId: null,
    start: 0.0,
    end: 1.0,
    translations: [],
  );
}
