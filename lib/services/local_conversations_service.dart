import 'dart:convert';
import 'dart:math' show min;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/services/local_metrics_service.dart';
import 'package:omi/services/omi_supabase_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

/// Service for storing and retrieving conversations locally
/// Used when direct Deepgram transcription is enabled (bypasses Omi backend)
class LocalConversationsService {
  static const String _storageKey = 'local_conversations_v1';
  static const int _maxStoredConversations = 100;

  /// Saves a conversation locally
  /// Optionally accepts a Structured object with full metadata (title, emoji, category, etc.)
  static Future<ServerConversation> saveConversation({
    required List<TranscriptSegment> segments,
    required DateTime startedAt,
    String? title,
    String? emoji,
    String? category,
    Structured? structured,
  }) async {
    final now = DateTime.now();
    final conversationId = const Uuid().v4();

    // Use provided structured data or create default
    final finalStructured = structured ??
        Structured(
          title ?? _generateDefaultTitle(startedAt),
          _generateOverview(segments),
          emoji: emoji ?? '🎤',
          category: category ?? 'personal',
        );

    // Create the conversation object
    final conversation = ServerConversation(
      id: conversationId,
      createdAt: now,
      startedAt: startedAt,
      finishedAt: now,
      structured: finalStructured,
      transcriptSegments: segments,
      status: ConversationStatus.completed,
      source: ConversationSource.friend,
    );

    await _addToStorage(conversation);

    // Record metrics
    final durationSeconds = now.difference(startedAt).inSeconds;
    final wordsCount = segments.fold<int>(0, (sum, s) => sum + s.text.split(' ').length);
    final insightsCount = finalStructured.actionItems.length + finalStructured.events.length;

    await LocalMetricsService.recordConversation(
      durationSeconds: durationSeconds,
      wordsCount: wordsCount,
      insightsCount: insightsCount,
      category: finalStructured.category,
    );

    // Save to Supabase (replaces Firestore)
    final firebaseUid = FirebaseAuth.instance.currentUser?.uid;
    if (firebaseUid != null) {
      try {
        await OmiSupabaseService.storeConversation(
          firebaseUid: firebaseUid,
          segments: segments,
          structured: finalStructured,
          startedAt: startedAt,
          finishedAt: now,
        );
        debugPrint('[LocalConversationsService] Saved to Supabase');
      } catch (e) {
        debugPrint('[LocalConversationsService] Failed to save to Supabase: $e');
      }
    }

    debugPrint('[LocalConversationsService] Saved conversation: $conversationId with ${segments.length} segments');
    debugPrint('[LocalConversationsService] Category: ${finalStructured.category}, Duration: ${durationSeconds}s, Words: $wordsCount');

    return conversation;
  }

  /// Updates an existing local conversation (e.g., after generating title/emoji)
  static Future<void> updateConversation(ServerConversation conversation) async {
    final conversations = getLocalConversations();
    final index = conversations.indexWhere((c) => c.id == conversation.id);

    if (index >= 0) {
      conversations[index] = conversation;
      await _saveAll(conversations);
      debugPrint('[LocalConversationsService] Updated conversation: ${conversation.id}');
    }
  }

  /// Gets all locally stored conversations
  static List<ServerConversation> getLocalConversations() {
    try {
      final prefs = SharedPreferencesUtil();
      final jsonList = prefs.getStringList(_storageKey);

      if (jsonList.isEmpty) return [];

      return jsonList
          .map((json) {
            try {
              return ServerConversation.fromJson(jsonDecode(json));
            } catch (e) {
              debugPrint('[LocalConversationsService] Error parsing conversation: $e');
              return null;
            }
          })
          .whereType<ServerConversation>()
          .toList();
    } catch (e) {
      debugPrint('[LocalConversationsService] Error loading conversations: $e');
      return [];
    }
  }

  /// Gets a specific local conversation by ID
  static ServerConversation? getConversation(String id) {
    final conversations = getLocalConversations();
    try {
      return conversations.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Deletes a local conversation by ID
  static Future<void> deleteConversation(String id) async {
    final conversations = getLocalConversations();
    conversations.removeWhere((c) => c.id == id);
    await _saveAll(conversations);
    debugPrint('[LocalConversationsService] Deleted conversation: $id');
  }

  /// Clears all local conversations
  static Future<void> clearAll() async {
    final prefs = SharedPreferencesUtil();
    await prefs.saveStringList(_storageKey, []);
    debugPrint('[LocalConversationsService] Cleared all local conversations');
  }

  /// Gets the count of local conversations
  static int getConversationCount() {
    return getLocalConversations().length;
  }

  /// Adds a conversation to storage (at the beginning of the list)
  static Future<void> _addToStorage(ServerConversation conv) async {
    final conversations = getLocalConversations();
    conversations.insert(0, conv);

    // Keep only the most recent conversations to prevent storage overflow
    if (conversations.length > _maxStoredConversations) {
      conversations.removeRange(_maxStoredConversations, conversations.length);
      debugPrint('[LocalConversationsService] Trimmed old conversations, keeping $_maxStoredConversations');
    }

    await _saveAll(conversations);
  }

  /// Saves all conversations to storage
  static Future<void> _saveAll(List<ServerConversation> convs) async {
    try {
      final prefs = SharedPreferencesUtil();
      final jsonList = convs.map((c) => jsonEncode(c.toJson())).toList();
      await prefs.saveStringList(_storageKey, jsonList);
    } catch (e) {
      debugPrint('[LocalConversationsService] Error saving conversations: $e');
    }
  }

  /// Generates a default title based on the date/time
  static String _generateDefaultTitle(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return 'Conversación ${date.day}/${date.month} $hour:$minute';
  }

  /// Generates an overview from transcript segments
  static String _generateOverview(List<TranscriptSegment> segments) {
    if (segments.isEmpty) return '';

    final text = segments.map((s) => s.text).join(' ').trim();
    if (text.isEmpty) return '';

    // Return first 300 characters as overview
    return text.length > 300 ? '${text.substring(0, 300)}...' : text;
  }

  /// Checks if a conversation exists locally
  static bool exists(String id) {
    return getLocalConversations().any((c) => c.id == id);
  }

  /// Merges local conversations with server conversations
  /// Local conversations are identified by checking if they don't exist in server list
  static List<ServerConversation> mergeWithServerConversations(
    List<ServerConversation> serverConversations,
  ) {
    final localConversations = getLocalConversations();
    final serverIds = serverConversations.map((c) => c.id).toSet();

    // Add local conversations that aren't on the server
    final uniqueLocalConversations = localConversations
        .where((local) => !serverIds.contains(local.id))
        .toList();

    // Combine and sort by created date (newest first)
    final merged = [...serverConversations, ...uniqueLocalConversations];
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return merged;
  }
}
