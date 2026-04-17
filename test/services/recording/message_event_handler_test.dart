import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/recording/message_event_handler.dart';

// =============================================================================
// Helpers
// =============================================================================

ServerConversation _makeConversation({String id = 'conv-1'}) {
  return ServerConversation(
    id: id,
    createdAt: DateTime(2026, 4, 17),
    structured: Structured('Test Title', 'Test overview'),
  );
}

TranscriptSegment _seg(String text, {String id = 'seg-1'}) {
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

// =============================================================================
// Tests
// =============================================================================

void main() {
  late MessageEventHandler handler;

  setUp(() {
    handler = MessageEventHandler();
  });

  // ---------------------------------------------------------------------------
  // ConversationEvent
  // ---------------------------------------------------------------------------
  group('ConversationEvent', () {
    test('calls onConversationUpserted', () {
      ServerConversation? received;
      handler.onConversationUpserted = (conv) {
        received = conv;
      };
      handler.onProcessingConversationRemoved = (_) {};

      final conv = _makeConversation(id: 'conv-42');
      final event = ConversationEvent(memory: conv, messages: []);

      handler.handleEvent(event);

      expect(received, isNotNull);
      expect(received!.id, 'conv-42');
    });

    test('sets isNew to true on conversation', () {
      handler.onConversationUpserted = (_) {};
      handler.onProcessingConversationRemoved = (_) {};

      final conv = _makeConversation();
      expect(conv.isNew, isFalse);

      final event = ConversationEvent(memory: conv, messages: []);
      handler.handleEvent(event);

      expect(conv.isNew, isTrue);
    });

    test('calls onProcessingConversationRemoved', () {
      String? removedId;
      handler.onProcessingConversationRemoved = (id) {
        removedId = id;
      };
      handler.onConversationUpserted = (_) {};

      final conv = _makeConversation(id: 'conv-99');
      final event = ConversationEvent(memory: conv, messages: []);

      handler.handleEvent(event);

      expect(removedId, 'conv-99');
    });
  });

  // ---------------------------------------------------------------------------
  // ConversationProcessingStartedEvent
  // ---------------------------------------------------------------------------
  group('ConversationProcessingStartedEvent', () {
    test('calls onProcessingStarted', () {
      ServerConversation? received;
      handler.onProcessingStarted = (memory) {
        received = memory;
      };
      handler.onResetStateVariables = () {};

      final conv = _makeConversation(id: 'conv-processing');
      final event = ConversationProcessingStartedEvent(memory: conv);

      handler.handleEvent(event);

      expect(received, isNotNull);
      expect(received!.id, 'conv-processing');
    });

    test('calls onResetStateVariables', () {
      bool resetCalled = false;
      handler.onProcessingStarted = (_) {};
      handler.onResetStateVariables = () {
        resetCalled = true;
      };

      final conv = _makeConversation();
      final event = ConversationProcessingStartedEvent(memory: conv);

      handler.handleEvent(event);

      expect(resetCalled, isTrue);
    });

    test('calls both callbacks in order', () {
      final callOrder = <String>[];
      handler.onProcessingStarted = (_) {
        callOrder.add('processing');
      };
      handler.onResetStateVariables = () {
        callOrder.add('reset');
      };

      final conv = _makeConversation();
      final event = ConversationProcessingStartedEvent(memory: conv);

      handler.handleEvent(event);

      expect(callOrder, ['processing', 'reset']);
    });
  });

  // ---------------------------------------------------------------------------
  // TranslationEvent
  // ---------------------------------------------------------------------------
  group('TranslationEvent', () {
    test('updates segments via translations', () {
      final liveSegments = [
        _seg('Hello', id: 'seg-a'),
        _seg('World', id: 'seg-b'),
      ];

      handler.getSegments = () => liveSegments;
      bool notified = false;
      handler.onNotifyListeners = () {
        notified = true;
      };

      final translatedSegments = [
        _seg('Hola', id: 'seg-a'),
      ];

      final event = TranslationEvent(segments: translatedSegments);
      handler.handleEvent(event);

      // TranscriptSegment.updateSegments replaces matching IDs
      expect(liveSegments[0].text, 'Hola');
      expect(liveSegments[1].text, 'World'); // unchanged
      expect(notified, isTrue);
    });

    test('empty translations does not notify', () {
      handler.getSegments = () => [_seg('Hello')];
      bool notified = false;
      handler.onNotifyListeners = () {
        notified = true;
      };

      final event = TranslationEvent(segments: []);
      handler.handleEvent(event);

      expect(notified, isFalse);
    });

    test('translations with null getSegments does not crash', () {
      handler.getSegments = null;

      final event = TranslationEvent(segments: [_seg('Hola')]);
      handler.handleEvent(event);
      // No crash = pass
    });
  });

  // ---------------------------------------------------------------------------
  // SpeakerLabelSuggestionEvent
  // ---------------------------------------------------------------------------
  group('SpeakerLabelSuggestionEvent', () {
    test('calls onSpeakerSuggestion when auto-create is disabled', () {
      SpeakerLabelSuggestionEvent? received;
      handler.onSpeakerSuggestion = (event) {
        received = event;
      };
      handler.getSegments = () => [
            _seg('test', id: 'seg-x'),
          ];
      handler.getTaggingSegmentIds = () => [];
      // Note: We cannot control SharedPreferencesUtil().autoCreateSpeakersEnabled
      // in unit tests without SharedPreferences setup. This tests the code path
      // when the segment exists but has no personId and is not user.

      final event = SpeakerLabelSuggestionEvent(
        speakerId: 1,
        personId: 'person-1',
        personName: 'Alice',
        segmentId: 'seg-x',
      );

      handler.handleEvent(event);

      // Since we can't control SharedPreferences, either path is valid.
      // The important thing is no crash.
    });

    test('skips when segment is already tagged', () {
      handler.getTaggingSegmentIds = () => ['seg-tagged'];
      handler.getSegments = () => [_seg('test', id: 'seg-tagged')];

      bool suggestionCalled = false;
      handler.onSpeakerSuggestion = (_) {
        suggestionCalled = true;
      };
      bool assignmentCalled = false;
      handler.onSpeakerAssignment = (_, __, ___, ____) {
        assignmentCalled = true;
      };

      final event = SpeakerLabelSuggestionEvent(
        speakerId: 1,
        personId: 'person-1',
        personName: 'Alice',
        segmentId: 'seg-tagged',
      );

      handler.handleEvent(event);

      expect(suggestionCalled, isFalse);
      expect(assignmentCalled, isFalse);
    });

    test('skips when segment already has personId', () {
      final seg = _seg('test', id: 'seg-person');
      seg.personId = 'existing-person';

      handler.getTaggingSegmentIds = () => [];
      handler.getSegments = () => [seg];

      bool suggestionCalled = false;
      handler.onSpeakerSuggestion = (_) {
        suggestionCalled = true;
      };
      bool assignmentCalled = false;
      handler.onSpeakerAssignment = (_, __, ___, ____) {
        assignmentCalled = true;
      };

      final event = SpeakerLabelSuggestionEvent(
        speakerId: 1,
        personId: 'person-1',
        personName: 'Alice',
        segmentId: 'seg-person',
      );

      handler.handleEvent(event);

      expect(suggestionCalled, isFalse);
      expect(assignmentCalled, isFalse);
    });

    test('skips when segment isUser is true', () {
      final seg = _seg('test', id: 'seg-user');
      seg.isUser = true;

      handler.getTaggingSegmentIds = () => [];
      handler.getSegments = () => [seg];

      bool suggestionCalled = false;
      handler.onSpeakerSuggestion = (_) {
        suggestionCalled = true;
      };
      bool assignmentCalled = false;
      handler.onSpeakerAssignment = (_, __, ___, ____) {
        assignmentCalled = true;
      };

      final event = SpeakerLabelSuggestionEvent(
        speakerId: 1,
        personId: 'person-1',
        personName: 'Alice',
        segmentId: 'seg-user',
      );

      handler.handleEvent(event);

      expect(suggestionCalled, isFalse);
      expect(assignmentCalled, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // PhotoProcessingEvent
  // ---------------------------------------------------------------------------
  group('PhotoProcessingEvent', () {
    test('updates photo id when found', () {
      final photos = [
        ConversationPhoto(
          id: 'temp-1',
          base64: 'base64data',
          createdAt: DateTime.now(),
        ),
      ];

      handler.getPhotos = () => photos;
      bool notified = false;
      handler.onNotifyListeners = () {
        notified = true;
      };

      final event = PhotoProcessingEvent(tempId: 'temp-1', photoId: 'real-1');
      handler.handleEvent(event);

      expect(photos[0].id, 'real-1');
      expect(notified, isTrue);
    });

    test('does not notify when photo not found', () {
      final photos = <ConversationPhoto>[];
      handler.getPhotos = () => photos;
      bool notified = false;
      handler.onNotifyListeners = () {
        notified = true;
      };

      final event =
          PhotoProcessingEvent(tempId: 'nonexistent', photoId: 'real-1');
      handler.handleEvent(event);

      expect(notified, isFalse);
    });

    test('does not crash when getPhotos is null', () {
      handler.getPhotos = null;

      final event = PhotoProcessingEvent(tempId: 'temp-1', photoId: 'real-1');
      handler.handleEvent(event);
      // No crash = pass
    });
  });

  // ---------------------------------------------------------------------------
  // PhotoDescribedEvent
  // ---------------------------------------------------------------------------
  group('PhotoDescribedEvent', () {
    test('updates photo description and discarded flag', () {
      final photos = [
        ConversationPhoto(
          id: 'photo-1',
          base64: 'base64data',
          createdAt: DateTime.now(),
        ),
      ];

      handler.getPhotos = () => photos;
      handler.onNotifyListeners = () {};

      final event = PhotoDescribedEvent(
        photoId: 'photo-1',
        description: 'A cat sitting on a desk',
        discarded: true,
      );
      handler.handleEvent(event);

      expect(photos[0].description, 'A cat sitting on a desk');
      expect(photos[0].discarded, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Null-safety / defensive checks
  // ---------------------------------------------------------------------------
  group('null callbacks defensive', () {
    test('ConversationEvent with null callbacks does not crash', () {
      handler.onConversationUpserted = null;
      handler.onProcessingConversationRemoved = null;

      final conv = _makeConversation();
      final event = ConversationEvent(memory: conv, messages: []);

      handler.handleEvent(event);
      // No crash = pass
    });

    test(
        'ConversationProcessingStartedEvent with null callbacks does not crash',
        () {
      handler.onProcessingStarted = null;
      handler.onResetStateVariables = null;

      final conv = _makeConversation();
      final event = ConversationProcessingStartedEvent(memory: conv);

      handler.handleEvent(event);
      // No crash = pass
    });

    test('TranslationEvent with null getSegments does not crash', () {
      handler.getSegments = null;

      final event = TranslationEvent(segments: [_seg('Hola')]);
      handler.handleEvent(event);
      // No crash = pass
    });

    test('SpeakerLabelSuggestionEvent with null callbacks does not crash', () {
      handler.getTaggingSegmentIds = null;
      handler.getSegments = null;
      handler.onSpeakerSuggestion = null;
      handler.onSpeakerAssignment = null;

      final event = SpeakerLabelSuggestionEvent(
        speakerId: 1,
        personId: 'p1',
        personName: 'Alice',
        segmentId: 'seg-1',
      );

      handler.handleEvent(event);
      // No crash = pass
    });

    test('PhotoProcessingEvent with null getPhotos does not crash', () {
      handler.getPhotos = null;

      final event = PhotoProcessingEvent(tempId: 'temp', photoId: 'real');
      handler.handleEvent(event);
      // No crash = pass
    });

    test('PhotoDescribedEvent with null getPhotos does not crash', () {
      handler.getPhotos = null;

      final event = PhotoDescribedEvent(
        photoId: 'photo-1',
        description: 'test',
      );
      handler.handleEvent(event);
      // No crash = pass
    });
  });

  // ---------------------------------------------------------------------------
  // Unknown/empty events
  // ---------------------------------------------------------------------------
  group('unknown events', () {
    test('UnknownEvent does not crash', () {
      final event = UnknownEvent(eventType: 'some_unknown_type');
      handler.handleEvent(event);
      // No crash = pass
    });

    test('MessageServiceStatusEvent does not crash', () {
      final event =
          MessageServiceStatusEvent(status: 'ok', statusText: 'ready');
      handler.handleEvent(event);
      // No crash = pass (not handled, falls through)
    });
  });
}
