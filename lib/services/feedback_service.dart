import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';

/// Types of feedback that can be submitted
enum FeedbackType {
  comment,
  bug,
  suggestion;

  String get value {
    switch (this) {
      case FeedbackType.comment:
        return 'comment';
      case FeedbackType.bug:
        return 'bug';
      case FeedbackType.suggestion:
        return 'suggestion';
    }
  }

  static FeedbackType fromString(String value) {
    switch (value) {
      case 'comment':
        return FeedbackType.comment;
      case 'bug':
        return FeedbackType.bug;
      case 'suggestion':
        return FeedbackType.suggestion;
      default:
        return FeedbackType.comment;
    }
  }
}

/// Model for a feedback submission
class FeedbackItem {
  final String id;
  final FeedbackType feedbackType;
  final String message;
  final String? appVersion;
  final String? deviceInfo;
  final String status;
  final DateTime createdAt;

  FeedbackItem({
    required this.id,
    required this.feedbackType,
    required this.message,
    this.appVersion,
    this.deviceInfo,
    required this.status,
    required this.createdAt,
  });

  factory FeedbackItem.fromJson(Map<String, dynamic> json) {
    return FeedbackItem(
      id: json['id'] as String,
      feedbackType: FeedbackType.fromString(json['feedback_type'] as String),
      message: json['message'] as String,
      appVersion: json['app_version'] as String?,
      deviceInfo: json['device_info'] as String?,
      status: json['status'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// Service for user feedback operations
class FeedbackService {
  static String get _baseUrl => Env.maityBackendUrl ?? 'https://maity-mobile.vercel.app';
  static const Duration _timeout = Duration(seconds: 30);

  /// Submits user feedback to the backend
  /// Returns the created FeedbackItem if successful, null otherwise
  static Future<FeedbackItem?> submitFeedback({
    required FeedbackType type,
    required String message,
    String? appVersion,
    String? deviceInfo,
  }) async {
    try {
      debugPrint('[FeedbackService] Submitting feedback: type=${type.value}');

      final authHeader = await getAuthHeader();
      if (authHeader.isEmpty || authHeader == 'Bearer ' || authHeader == 'Bearer null') {
        debugPrint('[FeedbackService] ERROR: Invalid or missing auth token');
        return null;
      }

      final response = await http
          .post(
            Uri.parse('$_baseUrl/v1/feedback/submit'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': authHeader,
            },
            body: jsonEncode({
              'feedback_type': type.value,
              'message': message,
              'app_version': appVersion,
              'device_info': deviceInfo,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('[FeedbackService] Feedback submitted successfully');
        return FeedbackItem.fromJson(data);
      } else {
        debugPrint('[FeedbackService] Submit failed: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[FeedbackService] Submit error: $e');
      return null;
    }
  }

  /// Gets all feedback (developers only - @asertio.mx)
  /// Returns list of FeedbackItem, empty list on error
  static Future<List<FeedbackItem>> getAllFeedback({
    int limit = 50,
    int offset = 0,
    String? status,
  }) async {
    try {
      debugPrint('[FeedbackService] Fetching all feedback (developer)');

      final authHeader = await getAuthHeader();
      if (authHeader.isEmpty || authHeader == 'Bearer ' || authHeader == 'Bearer null') {
        debugPrint('[FeedbackService] ERROR: Invalid or missing auth token');
        return [];
      }

      var url = '$_baseUrl/v1/feedback/list?limit=$limit&offset=$offset';
      if (status != null) {
        url += '&status=$status';
      }

      final response = await http
          .get(
            Uri.parse(url),
            headers: {'Authorization': authHeader},
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final feedbackList = (data['feedback'] as List)
            .map((item) => FeedbackItem.fromJson(item as Map<String, dynamic>))
            .toList();
        debugPrint('[FeedbackService] Fetched ${feedbackList.length} feedback items');
        return feedbackList;
      } else if (response.statusCode == 403) {
        debugPrint('[FeedbackService] Access denied - not a developer');
        return [];
      } else {
        debugPrint('[FeedbackService] Fetch failed: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('[FeedbackService] Fetch error: $e');
      return [];
    }
  }

  /// Gets the current user's own feedback
  static Future<List<FeedbackItem>> getMyFeedback({int limit = 20}) async {
    try {
      debugPrint('[FeedbackService] Fetching user feedback');

      final authHeader = await getAuthHeader();
      if (authHeader.isEmpty || authHeader == 'Bearer ' || authHeader == 'Bearer null') {
        debugPrint('[FeedbackService] ERROR: Invalid or missing auth token');
        return [];
      }

      final response = await http
          .get(
            Uri.parse('$_baseUrl/v1/feedback/my?limit=$limit'),
            headers: {'Authorization': authHeader},
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final feedbackList = (data['feedback'] as List)
            .map((item) => FeedbackItem.fromJson(item as Map<String, dynamic>))
            .toList();
        debugPrint('[FeedbackService] Fetched ${feedbackList.length} user feedback items');
        return feedbackList;
      } else {
        debugPrint('[FeedbackService] Fetch failed: ${response.statusCode} - ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('[FeedbackService] Fetch error: $e');
      return [];
    }
  }
}
