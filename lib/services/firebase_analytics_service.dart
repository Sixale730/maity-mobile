import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

/// Service for Firebase Analytics integration.
/// Provides screen tracking, event logging, and user identification.
class FirebaseAnalyticsService {
  static final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  /// Navigator observer for automatic screen tracking in MaterialApp
  static FirebaseAnalyticsObserver get observer =>
      FirebaseAnalyticsObserver(analytics: _analytics);

  // ==================== Screen Tracking ====================

  /// Log a screen view event
  static Future<void> logScreenView(String screenName, {String? screenClass}) async {
    try {
      await _analytics.logScreenView(
        screenName: screenName,
        screenClass: screenClass,
      );
      debugPrint('[Analytics] Screen view: $screenName');
    } catch (e) {
      debugPrint('[Analytics] Error logging screen view: $e');
    }
  }

  // ==================== User Identification ====================

  /// Set the user ID for analytics
  static Future<void> setUserId(String? userId) async {
    try {
      await _analytics.setUserId(id: userId);
      debugPrint('[Analytics] User ID set: ${userId != null ? 'yes' : 'cleared'}');
    } catch (e) {
      debugPrint('[Analytics] Error setting user ID: $e');
    }
  }

  /// Set a user property
  static Future<void> setUserProperty({
    required String name,
    required String? value,
  }) async {
    try {
      await _analytics.setUserProperty(name: name, value: value);
    } catch (e) {
      debugPrint('[Analytics] Error setting user property: $e');
    }
  }

  // ==================== Generic Event Logging ====================

  /// Log a custom event with optional parameters
  static Future<void> logEvent(
    String name, {
    Map<String, Object>? parameters,
  }) async {
    try {
      await _analytics.logEvent(
        name: name,
        parameters: parameters,
      );
      debugPrint('[Analytics] Event: $name');
    } catch (e) {
      debugPrint('[Analytics] Error logging event: $e');
    }
  }

  // ==================== Conversation Events ====================

  /// Log when a conversation is completed and saved
  static Future<void> logConversationCompleted({
    required int durationSeconds,
    required int segmentsCount,
    String? category,
  }) async {
    await logEvent('conversation_completed', parameters: {
      'duration_seconds': durationSeconds,
      'segments_count': segmentsCount,
      if (category != null) 'category': category,
    });
  }

  /// Log when a conversation is deleted
  static Future<void> logConversationDeleted({String? category}) async {
    await logEvent('conversation_deleted', parameters: {
      if (category != null) 'category': category,
    });
  }

  /// Log when recording starts
  static Future<void> logRecordingStarted({required String source}) async {
    await logEvent('recording_started', parameters: {
      'source': source, // 'phone_mic', 'bluetooth_device', 'system_audio'
    });
  }

  /// Log when recording stops
  static Future<void> logRecordingStopped({required int durationSeconds}) async {
    await logEvent('recording_stopped', parameters: {
      'duration_seconds': durationSeconds,
    });
  }

  // ==================== Action Items Events ====================

  /// Log when an action item is marked as completed
  static Future<void> logActionItemCompleted({String? source}) async {
    await logEvent('action_item_completed', parameters: {
      if (source != null) 'source': source,
    });
  }

  /// Log when an action item is created
  static Future<void> logActionItemCreated({
    bool fromConversation = false,
  }) async {
    await logEvent('action_item_created', parameters: {
      'from_conversation': fromConversation,
    });
  }

  /// Log when an action item is deleted
  static Future<void> logActionItemDeleted() async {
    await logEvent('action_item_deleted');
  }

  // ==================== Memory Events ====================

  /// Log when a memory is reviewed (approved or rejected)
  static Future<void> logMemoryReviewed({required bool approved}) async {
    await logEvent('memory_reviewed', parameters: {
      'approved': approved,
    });
  }

  /// Log when a memory is created manually
  static Future<void> logMemoryCreated({String? category}) async {
    await logEvent('memory_created', parameters: {
      'category': category ?? 'manual',
    });
  }

  /// Log when a memory is deleted
  static Future<void> logMemoryDeleted() async {
    await logEvent('memory_deleted');
  }

  /// Log when memories are extracted from a conversation
  static Future<void> logMemoriesExtracted({required int count}) async {
    await logEvent('memories_extracted', parameters: {
      'count': count,
    });
  }

  // ==================== Chat Events ====================

  /// Log when a chat message is sent
  static Future<void> logChatMessageSent({bool hasVoice = false}) async {
    await logEvent('chat_message_sent', parameters: {
      'has_voice': hasVoice,
    });
  }

  /// Log when a quick action is used in chat
  static Future<void> logQuickActionUsed({required String action}) async {
    await logEvent('quick_action_used', parameters: {
      'action': action,
    });
  }

  // ==================== Search Events ====================

  /// Log when a search is performed
  static Future<void> logSearch({required String searchType}) async {
    await logEvent('search_performed', parameters: {
      'search_type': searchType, // 'conversations', 'memories', 'semantic'
    });
  }

  // ==================== Settings Events ====================

  /// Log when language is changed
  static Future<void> logLanguageChanged({required String language}) async {
    await logEvent('language_changed', parameters: {
      'language': language,
    });
  }

  /// Log when a device is connected
  static Future<void> logDeviceConnected({required String deviceType}) async {
    await logEvent('device_connected', parameters: {
      'device_type': deviceType,
    });
  }

  // ==================== Onboarding Events ====================

  /// Log onboarding step completion
  static Future<void> logOnboardingStep({required String step}) async {
    await logEvent('onboarding_step', parameters: {
      'step': step,
    });
  }

  /// Log when onboarding is completed
  static Future<void> logOnboardingCompleted() async {
    await logEvent('onboarding_completed');
  }

  // ==================== Voice Profile Events ====================

  /// Log when voice profile enrollment starts
  static Future<void> logVoiceEnrollmentStarted() async {
    await logEvent('voice_enrollment_started');
  }

  /// Log when voice profile enrollment completes
  static Future<void> logVoiceEnrollmentCompleted({required bool success}) async {
    await logEvent('voice_enrollment_completed', parameters: {
      'success': success,
    });
  }

  // ==================== Feedback Events ====================

  /// Log when feedback is submitted
  static Future<void> logFeedbackSubmitted({required String feedbackType}) async {
    await logEvent('feedback_submitted', parameters: {
      'feedback_type': feedbackType, // 'comment', 'bug', 'suggestion'
    });
  }
}
