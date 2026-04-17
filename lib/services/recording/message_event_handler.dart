import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/message.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/utils/analytics/mixpanel.dart';

/// Routes message events received from the transcription socket to the
/// appropriate handlers.
///
/// Extracted from CaptureProvider to separate event routing from recording
/// orchestration. Uses callbacks for effects that need CaptureProvider state
/// (e.g. resetting state, notifying listeners, speaker assignment).
class MessageEventHandler {
  // ---------------------------------------------------------------------------
  // Callbacks for external effects
  // ---------------------------------------------------------------------------

  /// Called when a new conversation is created (upsert into provider).
  void Function(ServerConversation conversation)? onConversationCreated;

  /// Called when a processing-started event arrives.
  void Function(ServerConversation memory)? onProcessingStarted;

  /// Called when a processing-started event needs state reset.
  VoidCallback? onResetStateVariables;

  /// Called when a speaker label suggestion should be auto-assigned.
  void Function(int speakerId, String personId, String personName,
      List<String> segmentIds)? onSpeakerAssignment;

  /// Called when a speaker label suggestion should be shown (no auto-create).
  void Function(SpeakerLabelSuggestionEvent event)? onSpeakerSuggestion;

  /// Called to trigger ChangeNotifier.notifyListeners().
  VoidCallback? onNotifyListeners;

  // ---------------------------------------------------------------------------
  // Data accessors (injected by CaptureProvider)
  // ---------------------------------------------------------------------------

  /// Returns the current live segments list.
  List<TranscriptSegment> Function()? getSegments;

  /// Returns the current photos list.
  List<ConversationPhoto> Function()? getPhotos;

  /// Returns the current tagging segment IDs (to skip suggestions for them).
  List<String> Function()? getTaggingSegmentIds;

  /// Upsert a conversation into the provider (for LastConversationEvent).
  void Function(ServerConversation conversation)? onConversationUpserted;

  /// Remove a processing conversation by ID.
  void Function(String id)? onProcessingConversationRemoved;

  // ---------------------------------------------------------------------------
  // Event routing
  // ---------------------------------------------------------------------------

  /// Handle a message event from the transcription socket.
  void handleEvent(MessageEvent event) {
    if (event is ConversationProcessingStartedEvent) {
      onProcessingStarted?.call(event.memory);
      onResetStateVariables?.call();
      return;
    }
    if (event is ConversationEvent) {
      event.memory.isNew = true;
      onProcessingConversationRemoved?.call(event.memory.id);
      _processConversationCreated(
          event.memory, event.messages.cast<ServerMessage>());
      return;
    }
    if (event is LastConversationEvent) {
      _handleLastConvoEvent(event.memoryId);
      return;
    }
    if (event is SpeakerLabelSuggestionEvent) {
      _handleSpeakerLabelSuggestionEvent(event);
      return;
    }
    if (event is TranslationEvent) {
      _handleTranslationEvent(event.segments);
      return;
    }
    if (event is PhotoProcessingEvent) {
      final photos = getPhotos?.call();
      if (photos != null) {
        final idx = photos.indexWhere((p) => p.id == event.tempId);
        if (idx != -1) {
          photos[idx].id = event.photoId;
          onNotifyListeners?.call();
        }
      }
      return;
    }
    if (event is PhotoDescribedEvent) {
      final photos = getPhotos?.call();
      if (photos != null) {
        final idx = photos.indexWhere((p) => p.id == event.photoId);
        if (idx != -1) {
          photos[idx].description = event.description;
          photos[idx].discarded = event.discarded;
          onNotifyListeners?.call();
        }
      }
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // Internal handlers
  // ---------------------------------------------------------------------------

  void _processConversationCreated(
      ServerConversation? conversation, List<ServerMessage> messages) {
    if (conversation == null) return;
    onConversationUpserted?.call(conversation);
    MixpanelManager().conversationCreated(conversation);
  }

  Future<void> _handleLastConvoEvent(String memoryId) async {
    // Check if already exists — the callback will verify
    ServerConversation? conversation = await getConversationById(memoryId);
    if (conversation != null) {
      onConversationUpserted?.call(conversation);
    }
  }

  void _handleTranslationEvent(List<TranscriptSegment> translatedSegments) {
    if (translatedSegments.isEmpty) return;
    final segments = getSegments?.call();
    if (segments != null) {
      TranscriptSegment.updateSegments(segments, translatedSegments);
      onNotifyListeners?.call();
    }
  }

  void _handleSpeakerLabelSuggestionEvent(SpeakerLabelSuggestionEvent event) {
    final taggingIds = getTaggingSegmentIds?.call() ?? [];
    if (taggingIds.contains(event.segmentId)) return;

    final segments = getSegments?.call();
    if (segments != null) {
      var segment = segments.firstWhereOrNull((s) => s.id == event.segmentId);
      if (segment != null &&
          segment.id.isNotEmpty &&
          (segment.personId != null || segment.isUser)) {
        return;
      }
    }

    if (SharedPreferencesUtil().autoCreateSpeakersEnabled) {
      onSpeakerAssignment?.call(
          event.speakerId, event.personId, event.personName, [event.segmentId]);
    } else {
      onSpeakerSuggestion?.call(event);
    }
  }
}
