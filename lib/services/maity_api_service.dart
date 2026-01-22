import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/omi_supabase_service.dart';

/// Service for communicating with Maity backend API (Vercel)
/// Handles conversation processing, metrics, and action items
class MaityApiService {
  static String get _baseUrl => Env.maityBackendUrl ?? 'https://maity-mobile.vercel.app';
  static const Duration _timeout = Duration(seconds: 30);

  /// Process a conversation using the Maity backend
  /// Returns structured data with title, emoji, category, action items, events
  static Future<ProcessedConversationResponse?> processConversation({
    required String userId,
    required List<TranscriptSegment> segments,
    required DateTime startedAt,
    required DateTime finishedAt,
  }) async {
    if (segments.isEmpty) {
      debugPrint('[MaityApiService] No segments to process');
      return null;
    }

    try {
      debugPrint('[MaityApiService] Processing ${segments.length} segments for user $userId');

      final authHeader = await getAuthHeader();
      final response = await http
          .post(
            Uri.parse('$_baseUrl/v1/conversations/process'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': authHeader,
            },
            body: jsonEncode({
              'user_id': userId,
              'transcript_segments': segments
                  .map((s) => {
                        'text': s.text,
                        'speaker': s.personId?.toString(),
                        'speaker_id': s.speakerId,
                        'is_user': s.isUser,
                        'start': s.start,
                        'end': s.end,
                      })
                  .toList(),
              'started_at': startedAt.toUtc().toIso8601String(),
              'finished_at': finishedAt.toUtc().toIso8601String(),
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        debugPrint('[MaityApiService] Successfully processed conversation');
        final processed = ProcessedConversationResponse.fromJson(data);

        // Store in Supabase with vector embeddings for semantic search
        try {
          await OmiSupabaseService.storeConversation(
            userId: userId,
            segments: segments,
            structured: processed.structured,
            startedAt: startedAt,
            finishedAt: finishedAt,
          );
          debugPrint('[MaityApiService] Stored conversation in Supabase');
        } catch (e) {
          debugPrint('[MaityApiService] Failed to store in Supabase: $e');
          // Don't fail the whole operation if storage fails
        }

        return processed;
      } else {
        debugPrint('[MaityApiService] API error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[MaityApiService] Error processing conversation: $e');
      return null;
    }
  }

  /// Get user metrics for a specific period
  static Future<UserMetrics?> getMetrics(String userId, String period) async {
    try {
      final authHeader = await getAuthHeader();
      final response = await http
          .get(
            Uri.parse('$_baseUrl/v1/users/$userId/metrics?period=$period'),
            headers: {'Authorization': authHeader},
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return UserMetrics.fromJson(data);
      } else {
        debugPrint('[MaityApiService] Metrics error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('[MaityApiService] Error fetching metrics: $e');
      return null;
    }
  }

  /// Get metrics summary (today, monthly, all-time)
  static Future<MetricsSummary?> getMetricsSummary(String userId) async {
    try {
      final authHeader = await getAuthHeader();
      final response = await http
          .get(
            Uri.parse('$_baseUrl/v1/users/$userId/metrics/summary'),
            headers: {'Authorization': authHeader},
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return MetricsSummary.fromJson(data);
      } else {
        debugPrint('[MaityApiService] Summary error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('[MaityApiService] Error fetching summary: $e');
      return null;
    }
  }

  /// List user's action items
  static Future<List<ActionItemResponse>> getActionItems(
    String userId, {
    bool? completed,
    int limit = 50,
  }) async {
    try {
      var url = '$_baseUrl/v1/action-items?user_id=$userId&limit=$limit';
      if (completed != null) {
        url += '&completed=$completed';
      }

      final authHeader = await getAuthHeader();
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': authHeader},
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        return data.map((item) => ActionItemResponse.fromJson(item)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('[MaityApiService] Error fetching action items: $e');
      return [];
    }
  }

  /// Update action item completion status
  static Future<bool> updateActionItem(
    String userId,
    String itemId, {
    bool? completed,
    String? description,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (completed != null) body['completed'] = completed;
      if (description != null) body['description'] = description;

      final authHeader = await getAuthHeader();
      final response = await http
          .patch(
            Uri.parse('$_baseUrl/v1/action-items/$itemId?user_id=$userId'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': authHeader,
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[MaityApiService] Error updating action item: $e');
      return false;
    }
  }

  /// Check if backend is available
  static Future<bool> isAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Set the starred (favorite) status of a conversation
  static Future<bool> setConversationStarred(
    String conversationId,
    String userId,
    bool starred,
  ) async {
    try {
      final authHeader = await getAuthHeader();
      final response = await http
          .patch(
            Uri.parse('$_baseUrl/v1/omi/conversations/$conversationId/starred?starred=$starred&user_id=$userId'),
            headers: {'Authorization': authHeader},
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        debugPrint('[MaityApiService] Successfully set starred=$starred for conversation $conversationId');
        return true;
      } else {
        debugPrint('[MaityApiService] Set starred error: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('[MaityApiService] Error setting starred: $e');
      return false;
    }
  }
}

/// Response from processing a conversation
class ProcessedConversationResponse {
  final String id;
  final DateTime createdAt;
  final DateTime startedAt;
  final DateTime finishedAt;
  final Structured structured;
  final ConversationMetrics metrics;

  ProcessedConversationResponse({
    required this.id,
    required this.createdAt,
    required this.startedAt,
    required this.finishedAt,
    required this.structured,
    required this.metrics,
  });

  factory ProcessedConversationResponse.fromJson(Map<String, dynamic> json) {
    return ProcessedConversationResponse(
      id: json['id'] ?? '',
      createdAt: DateTime.parse(json['created_at']).toLocal(),
      startedAt: DateTime.parse(json['started_at']).toLocal(),
      finishedAt: DateTime.parse(json['finished_at']).toLocal(),
      structured: Structured.fromJson(json['structured']),
      metrics: ConversationMetrics.fromJson(json['metrics']),
    );
  }
}

/// Metrics for a single conversation
class ConversationMetrics {
  final int wordsCount;
  final int durationSeconds;
  final int insightsCount;

  ConversationMetrics({
    required this.wordsCount,
    required this.durationSeconds,
    required this.insightsCount,
  });

  factory ConversationMetrics.fromJson(Map<String, dynamic> json) {
    return ConversationMetrics(
      wordsCount: json['words_count'] ?? 0,
      durationSeconds: json['duration_seconds'] ?? 0,
      insightsCount: json['insights_count'] ?? 0,
    );
  }
}

/// User metrics response
class UserMetrics {
  final String period;
  final String userId;
  final UserStats stats;
  final List<DailyMetrics> history;

  UserMetrics({
    required this.period,
    required this.userId,
    required this.stats,
    required this.history,
  });

  factory UserMetrics.fromJson(Map<String, dynamic> json) {
    return UserMetrics(
      period: json['period'] ?? '',
      userId: json['user_id'] ?? '',
      stats: UserStats.fromJson(json['stats'] ?? {}),
      history: (json['history'] as List<dynamic>?)
              ?.map((h) => DailyMetrics.fromJson(h))
              .toList() ??
          [],
    );
  }
}

/// User statistics
class UserStats {
  final int transcriptionSeconds;
  final int wordsTranscribed;
  final int conversationsCount;
  final int insightsGained;
  final int memoriesCount;
  final List<CategoryCount> topCategories;

  UserStats({
    required this.transcriptionSeconds,
    required this.wordsTranscribed,
    required this.conversationsCount,
    required this.insightsGained,
    required this.memoriesCount,
    required this.topCategories,
  });

  factory UserStats.fromJson(Map<String, dynamic> json) {
    return UserStats(
      transcriptionSeconds: json['transcription_seconds'] ?? 0,
      wordsTranscribed: json['words_transcribed'] ?? 0,
      conversationsCount: json['conversations_count'] ?? 0,
      insightsGained: json['insights_gained'] ?? 0,
      memoriesCount: json['memories_count'] ?? 0,
      topCategories: (json['top_categories'] as List<dynamic>?)
              ?.map((c) => CategoryCount.fromJson(c))
              .toList() ??
          [],
    );
  }
}

/// Category count
class CategoryCount {
  final String category;
  final int count;

  CategoryCount({required this.category, required this.count});

  factory CategoryCount.fromJson(Map<String, dynamic> json) {
    return CategoryCount(
      category: json['category'] ?? '',
      count: json['count'] ?? 0,
    );
  }
}

/// Daily metrics
class DailyMetrics {
  final String date;
  final int conversations;
  final double minutes;
  final int words;
  final int insights;
  final int memories;

  DailyMetrics({
    required this.date,
    required this.conversations,
    required this.minutes,
    required this.words,
    required this.insights,
    required this.memories,
  });

  factory DailyMetrics.fromJson(Map<String, dynamic> json) {
    return DailyMetrics(
      date: json['date'] ?? '',
      conversations: json['conversations'] ?? 0,
      minutes: (json['minutes'] ?? 0).toDouble(),
      words: json['words'] ?? 0,
      insights: json['insights'] ?? 0,
      memories: json['memories'] ?? 0,
    );
  }
}

/// Metrics summary (today, monthly, all-time)
class MetricsSummary {
  final String userId;
  final PeriodMetrics today;
  final PeriodMetrics monthly;
  final AllTimeMetrics allTime;

  MetricsSummary({
    required this.userId,
    required this.today,
    required this.monthly,
    required this.allTime,
  });

  factory MetricsSummary.fromJson(Map<String, dynamic> json) {
    return MetricsSummary(
      userId: json['user_id'] ?? '',
      today: PeriodMetrics.fromJson(json['today'] ?? {}),
      monthly: PeriodMetrics.fromJson(json['monthly'] ?? {}),
      allTime: AllTimeMetrics.fromJson(json['all_time'] ?? {}),
    );
  }
}

/// Period metrics (today/monthly)
class PeriodMetrics {
  final int conversations;
  final double minutes;
  final int words;
  final int insights;

  PeriodMetrics({
    required this.conversations,
    required this.minutes,
    required this.words,
    this.insights = 0,
  });

  factory PeriodMetrics.fromJson(Map<String, dynamic> json) {
    return PeriodMetrics(
      conversations: json['conversations'] ?? 0,
      minutes: (json['minutes'] ?? 0).toDouble(),
      words: json['words'] ?? 0,
      insights: json['insights'] ?? 0,
    );
  }
}

/// All-time metrics with categories
class AllTimeMetrics extends PeriodMetrics {
  final List<CategoryCount> topCategories;

  AllTimeMetrics({
    required super.conversations,
    required super.minutes,
    required super.words,
    required super.insights,
    required this.topCategories,
  });

  factory AllTimeMetrics.fromJson(Map<String, dynamic> json) {
    return AllTimeMetrics(
      conversations: json['conversations'] ?? 0,
      minutes: (json['minutes'] ?? 0).toDouble(),
      words: json['words'] ?? 0,
      insights: json['insights'] ?? 0,
      topCategories: (json['top_categories'] as List<dynamic>?)
              ?.map((c) => CategoryCount.fromJson(c))
              .toList() ??
          [],
    );
  }
}

/// Action item response
class ActionItemResponse {
  final String id;
  final String description;
  final bool completed;
  final DateTime? dueAt;
  final String? conversationId;
  final DateTime createdAt;

  ActionItemResponse({
    required this.id,
    required this.description,
    required this.completed,
    this.dueAt,
    this.conversationId,
    required this.createdAt,
  });

  factory ActionItemResponse.fromJson(Map<String, dynamic> json) {
    return ActionItemResponse(
      id: json['id'] ?? '',
      description: json['description'] ?? '',
      completed: json['completed'] ?? false,
      dueAt: json['due_at'] != null ? DateTime.parse(json['due_at']).toLocal() : null,
      conversationId: json['conversation_id'],
      createdAt: DateTime.parse(json['created_at']).toLocal(),
    );
  }
}
