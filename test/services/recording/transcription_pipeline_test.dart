import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/recording/transcription_pipeline.dart';

void main() {
  late TranscriptionPipeline pipeline;

  setUp(() {
    pipeline = TranscriptionPipeline();
  });

  tearDown(() async {
    // Dispose without calling the full dispose (which disposes vadStateNotifier)
    // since tests may not have initialized VAD.
    pipeline.stopKeepAlive();
    pipeline.stopHealthMonitor();
    pipeline.cancelSilenceTimer();
  });

  group('Initial state', () {
    test('segments list is empty', () {
      expect(pipeline.segments, isEmpty);
    });

    test('segmentsVersion starts at 0', () {
      expect(pipeline.segmentsVersion, 0);
    });

    test('hasTranscripts is false', () {
      expect(pipeline.hasTranscripts, isFalse);
    });

    test('isConnected defaults to true', () {
      expect(pipeline.isConnected, isTrue);
    });

    test('transcriptServiceReady is false initially', () {
      expect(pipeline.transcriptServiceReady, isFalse);
    });

    test('isReconnectingSocket is false initially', () {
      expect(pipeline.isReconnectingSocket, isFalse);
    });

    test('isVadActive is false initially', () {
      expect(pipeline.isVadActive, isFalse);
    });

    test('vadMetrics is null initially', () {
      expect(pipeline.vadMetrics, isNull);
    });
  });

  group('clearSegments', () {
    test('resets all segment state', () {
      // Manually add some segments
      pipeline.segments.addAll([
        _makeSegment('s1', 'Hello', 0.0, 1.0),
        _makeSegment('s2', 'World', 1.0, 2.0),
      ]);
      pipeline.hasTranscripts = true;

      pipeline.clearSegments();

      expect(pipeline.segments, isEmpty);
      expect(pipeline.segmentsVersion, 0);
      expect(pipeline.hasTranscripts, isFalse);
      expect(pipeline.transcriptionServiceStatuses, isEmpty);
    });
  });

  group('onConnectionStateChanged', () {
    test('updates isConnected', () {
      bool notified = false;
      pipeline.onNotifyListeners = () => notified = true;

      pipeline.onConnectionStateChanged(false);

      expect(pipeline.isConnected, isFalse);
      expect(notified, isTrue);
    });

    test('restores isConnected', () {
      pipeline.onConnectionStateChanged(false);
      pipeline.onConnectionStateChanged(true);

      expect(pipeline.isConnected, isTrue);
    });
  });

  group('maxAudioBufferBytes', () {
    test('is 160000 (~5 seconds at 16kHz PCM16)', () {
      expect(TranscriptionPipeline.maxAudioBufferBytes, 160000);
    });
  });

  group('setHasTranscripts', () {
    test('sets hasTranscripts to true', () {
      pipeline.setHasTranscripts(true);
      expect(pipeline.hasTranscripts, isTrue);
    });

    test('sets hasTranscripts to false', () {
      pipeline.setHasTranscripts(true);
      pipeline.setHasTranscripts(false);
      expect(pipeline.hasTranscripts, isFalse);
    });
  });
}

/// Helper to create a minimal TranscriptSegment for testing.
TranscriptSegment _makeSegment(
    String id, String text, double start, double end) {
  return TranscriptSegment(
    id: id,
    text: text,
    speaker: 'SPEAKER_00',
    isUser: false,
    personId: null,
    start: start,
    end: end,
    translations: [],
  );
}
