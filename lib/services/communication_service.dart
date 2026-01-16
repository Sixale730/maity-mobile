import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/communication_feedback.dart';

/// Service for communication feedback analysis
class CommunicationService {
  static String get _baseUrl =>
      Env.maityBackendUrl ?? 'https://maity-mobile.vercel.app';
  static const Duration _timeout = Duration(seconds: 30);

  /// Get aggregated communication feedback for a user
  /// [userId] es el UUID de maity.users
  /// [period] puede ser: today, weekly, monthly, yearly, all
  static Future<CommunicationFeedbackResponse?> getFeedback({
    required String userId,
    String period = 'monthly',
  }) async {
    try {
      debugPrint(
          '[CommunicationService] Getting feedback for user $userId, period: $period');

      final authHeader = await getAuthHeader();
      final response = await http
          .get(
            Uri.parse(
                '$_baseUrl/v1/communication/feedback?user_id=$userId&period=$period'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': authHeader,
            },
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        debugPrint(
            '[CommunicationService] Got feedback: ${data['feedback']['conversations_analyzed']} conversations analyzed');
        return CommunicationFeedbackResponse.fromJson(data);
      } else {
        debugPrint(
            '[CommunicationService] Error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[CommunicationService] Error getting feedback: $e');
      return null;
    }
  }

  /// Get communication feedback for a specific conversation
  static Future<CommunicationFeedback?> getConversationFeedback({
    required String userId,
    required String conversationId,
  }) async {
    try {
      debugPrint(
          '[CommunicationService] Getting feedback for conversation $conversationId');

      final authHeader = await getAuthHeader();
      final response = await http
          .get(
            Uri.parse(
                '$_baseUrl/v1/communication/feedback/$conversationId?user_id=$userId'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': authHeader,
            },
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data['feedback'] != null) {
          return CommunicationFeedback.fromJson(data['feedback']);
        }
        return null;
      } else {
        debugPrint(
            '[CommunicationService] Error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint(
          '[CommunicationService] Error getting conversation feedback: $e');
      return null;
    }
  }
}
