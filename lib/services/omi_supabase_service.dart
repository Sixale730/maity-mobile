import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/backend/schema/transcript_segment.dart';

/// Service for OMI wearable data storage in Supabase
/// All operations go through Vercel backend which uses service_role key
class OmiSupabaseService {
  static const String _baseUrl = 'https://maity-backend.vercel.app';
  static const Duration _timeout = Duration(seconds: 60);

  /// Store a processed conversation with embeddings in Supabase
  static Future<StoredConversationResponse?> storeConversation({
    required String firebaseUid,
    required List<TranscriptSegment> segments,
    required Structured structured,
    required DateTime startedAt,
    required DateTime finishedAt,
    String source = 'omi',
    String? language,
    bool generateEmbeddings = true,
  }) async {
    if (segments.isEmpty) {
      debugPrint('[OmiSupabaseService] No segments to store');
      return null;
    }

    try {
      debugPrint('[OmiSupabaseService] Storing conversation for user $firebaseUid');

      final authHeader = await getAuthHeader();
      final response = await http
          .post(
            Uri.parse('$_baseUrl/v1/omi/conversations/store'),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': authHeader,
            },
            body: jsonEncode({
              'firebase_uid': firebaseUid,
              'started_at': startedAt.toUtc().toIso8601String(),
              'finished_at': finishedAt.toUtc().toIso8601String(),
              'structured': {
                'title': structured.title,
                'overview': structured.overview,
                'emoji': structured.emoji,
                'category': structured.category,
                'action_items': structured.actionItems.map((a) => a.toJson()).toList(),
                'events': structured.events.map((e) => e.toJson()).toList(),
              },
              'transcript_segments': segments
                  .map((s) => {
                        'text': s.text,
                        'speaker': s.speaker,
                        'speaker_id': s.speakerId,
                        'is_user': s.isUser,
                        'person_id': s.personId,
                        'start': s.start,
                        'end': s.end,
                      })
                  .toList(),
              'source': source,
              'language': language,
              'generate_embeddings': generateEmbeddings,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        debugPrint('[OmiSupabaseService] Stored conversation: ${data['id']}');
        return StoredConversationResponse.fromJson(data);
      } else {
        debugPrint('[OmiSupabaseService] Store error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[OmiSupabaseService] Error storing conversation: $e');
      return null;
    }
  }

  /// Semantic search for conversations using vector similarity
  static Future<List<SemanticSearchResult>> searchConversations({
    required String firebaseUid,
    required String query,
    int limit = 10,
    double similarityThreshold = 0.7,
    bool includeDiscarded = false,
  }) async {
    if (query.isEmpty) return [];

    try {
      debugPrint('[OmiSupabaseService] Semantic search: "$query"');

      final authHeader = await getAuthHeader();
      final response = await http
          .post(
            Uri.parse('$_baseUrl/v1/omi/conversations/search'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': authHeader,
            },
            body: jsonEncode({
              'query': query,
              'firebase_uid': firebaseUid,
              'limit': limit,
              'search_type': 'conversations',
              'similarity_threshold': similarityThreshold,
              'include_discarded': includeDiscarded,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final results = (data['results'] as List).map((r) => SemanticSearchResult.fromJson(r)).toList();
        debugPrint('[OmiSupabaseService] Found ${results.length} results');
        return results;
      }
      return [];
    } catch (e) {
      debugPrint('[OmiSupabaseService] Search error: $e');
      return [];
    }
  }

  /// Semantic search for specific transcript segments (granular search)
  static Future<List<SegmentSearchResult>> searchSegments({
    required String firebaseUid,
    required String query,
    int limit = 20,
    double similarityThreshold = 0.7,
  }) async {
    if (query.isEmpty) return [];

    try {
      final authHeader = await getAuthHeader();
      final response = await http
          .post(
            Uri.parse('$_baseUrl/v1/omi/conversations/search'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': authHeader,
            },
            body: jsonEncode({
              'query': query,
              'firebase_uid': firebaseUid,
              'limit': limit,
              'search_type': 'segments',
              'similarity_threshold': similarityThreshold,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return (data['results'] as List).map((r) => SegmentSearchResult.fromJson(r)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('[OmiSupabaseService] Segment search error: $e');
      return [];
    }
  }

  /// List conversations from Supabase with pagination
  static Future<List<OmiConversation>> getConversations({
    required String firebaseUid,
    int limit = 50,
    int offset = 0,
    bool includeDiscarded = false,
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/v1/omi/conversations').replace(
        queryParameters: {
          'firebase_uid': firebaseUid,
          'limit': limit.toString(),
          'offset': offset.toString(),
          'include_discarded': includeDiscarded.toString(),
        },
      );

      final authHeader = await getAuthHeader();
      final response = await http.get(
        uri,
        headers: {'Authorization': authHeader},
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return (data['conversations'] as List).map((c) => OmiConversation.fromJson(c)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('[OmiSupabaseService] Get conversations error: $e');
      return [];
    }
  }

  /// Get a single conversation with all its segments
  static Future<OmiConversationDetail?> getConversation({
    required String firebaseUid,
    required String conversationId,
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/v1/omi/conversations/$conversationId').replace(
        queryParameters: {'firebase_uid': firebaseUid},
      );

      final authHeader = await getAuthHeader();
      final response = await http.get(
        uri,
        headers: {'Authorization': authHeader},
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return OmiConversationDetail.fromJson(data);
      }
      return null;
    } catch (e) {
      debugPrint('[OmiSupabaseService] Get conversation error: $e');
      return null;
    }
  }
}

/// Response from storing a conversation
class StoredConversationResponse {
  final String id;
  final DateTime createdAt;
  final bool embeddingGenerated;

  StoredConversationResponse({
    required this.id,
    required this.createdAt,
    required this.embeddingGenerated,
  });

  factory StoredConversationResponse.fromJson(Map<String, dynamic> json) {
    return StoredConversationResponse(
      id: json['id'],
      createdAt: DateTime.parse(json['created_at']),
      embeddingGenerated: json['embedding_generated'] ?? false,
    );
  }
}

/// Semantic search result for conversations
class SemanticSearchResult {
  final String id;
  final String title;
  final String overview;
  final String emoji;
  final String category;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int wordsCount;
  final int durationSeconds;
  final double similarity;

  SemanticSearchResult({
    required this.id,
    required this.title,
    required this.overview,
    required this.emoji,
    required this.category,
    required this.createdAt,
    this.startedAt,
    this.finishedAt,
    required this.wordsCount,
    required this.durationSeconds,
    required this.similarity,
  });

  factory SemanticSearchResult.fromJson(Map<String, dynamic> json) {
    return SemanticSearchResult(
      id: json['id'],
      title: json['title'] ?? '',
      overview: json['overview'] ?? '',
      emoji: json['emoji'] ?? '',
      category: json['category'] ?? 'other',
      createdAt: DateTime.parse(json['created_at']),
      startedAt: json['started_at'] != null ? DateTime.parse(json['started_at']) : null,
      finishedAt: json['finished_at'] != null ? DateTime.parse(json['finished_at']) : null,
      wordsCount: json['words_count'] ?? 0,
      durationSeconds: json['duration_seconds'] ?? 0,
      similarity: (json['similarity'] as num).toDouble(),
    );
  }
}

/// Semantic search result for transcript segments
class SegmentSearchResult {
  final String segmentId;
  final String conversationId;
  final String text;
  final String? speaker;
  final bool isUser;
  final double startTime;
  final double endTime;
  final String conversationTitle;
  final double similarity;

  SegmentSearchResult({
    required this.segmentId,
    required this.conversationId,
    required this.text,
    this.speaker,
    required this.isUser,
    required this.startTime,
    required this.endTime,
    required this.conversationTitle,
    required this.similarity,
  });

  factory SegmentSearchResult.fromJson(Map<String, dynamic> json) {
    return SegmentSearchResult(
      segmentId: json['segment_id'],
      conversationId: json['conversation_id'],
      text: json['text'] ?? '',
      speaker: json['speaker'],
      isUser: json['is_user'] ?? false,
      startTime: (json['start_time'] as num).toDouble(),
      endTime: (json['end_time'] as num).toDouble(),
      conversationTitle: json['conversation_title'] ?? '',
      similarity: (json['similarity'] as num).toDouble(),
    );
  }
}

/// Conversation from Supabase
class OmiConversation {
  final String id;
  final String title;
  final String overview;
  final String emoji;
  final String category;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int wordsCount;
  final int durationSeconds;
  final String status;
  final bool discarded;

  OmiConversation({
    required this.id,
    required this.title,
    required this.overview,
    required this.emoji,
    required this.category,
    required this.createdAt,
    this.startedAt,
    this.finishedAt,
    required this.wordsCount,
    required this.durationSeconds,
    required this.status,
    required this.discarded,
  });

  factory OmiConversation.fromJson(Map<String, dynamic> json) {
    return OmiConversation(
      id: json['id'],
      title: json['title'] ?? '',
      overview: json['overview'] ?? '',
      emoji: json['emoji'] ?? '',
      category: json['category'] ?? 'other',
      createdAt: DateTime.parse(json['created_at']),
      startedAt: json['started_at'] != null ? DateTime.parse(json['started_at']) : null,
      finishedAt: json['finished_at'] != null ? DateTime.parse(json['finished_at']) : null,
      wordsCount: json['words_count'] ?? 0,
      durationSeconds: json['duration_seconds'] ?? 0,
      status: json['status'] ?? 'completed',
      discarded: json['discarded'] ?? false,
    );
  }
}

/// Conversation detail with segments
class OmiConversationDetail {
  final OmiConversation conversation;
  final List<OmiSegment> segments;

  OmiConversationDetail({
    required this.conversation,
    required this.segments,
  });

  factory OmiConversationDetail.fromJson(Map<String, dynamic> json) {
    final convJson = json['conversation'] as Map<String, dynamic>;
    final segsJson = json['segments'] as List;
    return OmiConversationDetail(
      conversation: OmiConversation.fromJson(convJson),
      segments: segsJson.map((s) => OmiSegment.fromJson(s)).toList(),
    );
  }
}

/// Transcript segment from Supabase
class OmiSegment {
  final String id;
  final int segmentIndex;
  final String text;
  final String? speaker;
  final int speakerId;
  final bool isUser;
  final String? personId;
  final double startTime;
  final double endTime;

  OmiSegment({
    required this.id,
    required this.segmentIndex,
    required this.text,
    this.speaker,
    required this.speakerId,
    required this.isUser,
    this.personId,
    required this.startTime,
    required this.endTime,
  });

  factory OmiSegment.fromJson(Map<String, dynamic> json) {
    return OmiSegment(
      id: json['id'],
      segmentIndex: json['segment_index'] ?? 0,
      text: json['text'] ?? '',
      speaker: json['speaker'],
      speakerId: json['speaker_id'] ?? 0,
      isUser: json['is_user'] ?? false,
      personId: json['person_id'],
      startTime: (json['start_time'] as num).toDouble(),
      endTime: (json['end_time'] as num).toDouble(),
    );
  }
}
