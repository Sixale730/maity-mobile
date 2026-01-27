import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/memory.dart';
import 'package:omi/env/env.dart';

/// Base URL for memories API
String get _memoriesBaseUrl => '${Env.maityBackendUrl}/v1/memories';

/// List memories with optional filters
Future<MemoryListResponse> getMemories({
  int limit = 50,
  int offset = 0,
  String? category,
  bool includeDeleted = false,
  bool reviewedOnly = false,
  bool pendingOnly = false,
}) async {
  final queryParams = <String, String>{
    'limit': limit.toString(),
    'offset': offset.toString(),
    if (category != null) 'category': category,
    if (includeDeleted) 'include_deleted': 'true',
    if (reviewedOnly) 'reviewed_only': 'true',
    if (pendingOnly) 'pending_only': 'true',
  };

  final uri = Uri.parse(_memoriesBaseUrl).replace(queryParameters: queryParams);

  var response = await makeApiCall(
    url: uri.toString(),
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] getMemories failed: ${response?.statusCode}');
    return MemoryListResponse(memories: [], total: 0, pendingReview: 0);
  }

  try {
    final data = json.decode(response.body);
    return MemoryListResponse.fromJson(data);
  } catch (e) {
    debugPrint('[Memories] Error parsing response: $e');
    return MemoryListResponse(memories: [], total: 0, pendingReview: 0);
  }
}

/// Get a specific memory by ID
Future<Memory?> getMemory(String memoryId) async {
  var response = await makeApiCall(
    url: '$_memoriesBaseUrl/$memoryId',
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] getMemory failed: ${response?.statusCode}');
    return null;
  }

  try {
    final data = json.decode(response.body);
    return Memory.fromJson(data);
  } catch (e) {
    debugPrint('[Memories] Error parsing memory: $e');
    return null;
  }
}

/// Create a new memory manually
Future<Memory?> createMemoryServer({
  required String content,
  String visibility = 'private',
  String? conversationId,
}) async {
  var response = await makeApiCall(
    url: _memoriesBaseUrl,
    headers: {},
    method: 'POST',
    body: json.encode({
      'content': content,
      'visibility': visibility,
      if (conversationId != null) 'conversation_id': conversationId,
    }),
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] createMemory failed: ${response?.statusCode}');
    return null;
  }

  try {
    final data = json.decode(response.body);
    debugPrint('[Memories] Created memory: ${data['id']}');
    return Memory.fromJson(data);
  } catch (e) {
    debugPrint('[Memories] Error parsing created memory: $e');
    return null;
  }
}

/// Update a memory's content or visibility
Future<Memory?> updateMemoryServer({
  required String memoryId,
  String? content,
  String? visibility,
}) async {
  final body = <String, dynamic>{};
  if (content != null) body['content'] = content;
  if (visibility != null) body['visibility'] = visibility;

  var response = await makeApiCall(
    url: '$_memoriesBaseUrl/$memoryId',
    headers: {},
    method: 'PATCH',
    body: json.encode(body),
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] updateMemory failed: ${response?.statusCode}');
    return null;
  }

  try {
    final data = json.decode(response.body);
    debugPrint('[Memories] Updated memory: $memoryId');
    return Memory.fromJson(data);
  } catch (e) {
    debugPrint('[Memories] Error parsing updated memory: $e');
    return null;
  }
}

/// Update memory visibility
Future<bool> updateMemoryVisibilityServer(String memoryId, String visibility) async {
  final result = await updateMemoryServer(memoryId: memoryId, visibility: visibility);
  return result != null;
}

/// Review a memory (approve or reject)
Future<Memory?> reviewMemoryServer(String memoryId, bool approved) async {
  var response = await makeApiCall(
    url: '$_memoriesBaseUrl/$memoryId/review',
    headers: {},
    method: 'POST',
    body: json.encode({'approved': approved}),
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] reviewMemory failed: ${response?.statusCode}');
    return null;
  }

  try {
    final data = json.decode(response.body);
    debugPrint('[Memories] Reviewed memory $memoryId: approved=$approved');
    return Memory.fromJson(data);
  } catch (e) {
    debugPrint('[Memories] Error parsing reviewed memory: $e');
    return null;
  }
}

/// Delete a memory (soft delete by default)
Future<bool> deleteMemoryServer(String memoryId, {bool hardDelete = false}) async {
  final queryParams = hardDelete ? '?hard_delete=true' : '';

  var response = await makeApiCall(
    url: '$_memoriesBaseUrl/$memoryId$queryParams',
    headers: {},
    method: 'DELETE',
    body: '',
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] deleteMemory failed: ${response?.statusCode}');
    return false;
  }

  debugPrint('[Memories] Deleted memory: $memoryId');
  return true;
}

/// Extract memories from a conversation using AI
Future<ExtractMemoriesResponse?> extractMemoriesFromConversation(String conversationId) async {
  var response = await makeApiCall(
    url: '$_memoriesBaseUrl/extract',
    headers: {},
    method: 'POST',
    body: json.encode({'conversation_id': conversationId}),
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] extractMemories failed: ${response?.statusCode}');
    return null;
  }

  try {
    final data = json.decode(response.body);
    debugPrint('[Memories] Extracted ${data['memories_created']} memories from $conversationId');
    return ExtractMemoriesResponse.fromJson(data);
  } catch (e) {
    debugPrint('[Memories] Error parsing extracted memories: $e');
    return null;
  }
}

/// Search memories using semantic similarity
Future<List<Memory>> searchMemories({
  required String query,
  int limit = 10,
  String? category,
  bool includeDeleted = false,
}) async {
  var response = await makeApiCall(
    url: '$_memoriesBaseUrl/search',
    headers: {},
    method: 'POST',
    body: json.encode({
      'query': query,
      'limit': limit,
      if (category != null) 'category': category,
      'include_deleted': includeDeleted,
    }),
  );

  if (response == null || response.statusCode != 200) {
    debugPrint('[Memories] searchMemories failed: ${response?.statusCode}');
    return [];
  }

  try {
    final data = json.decode(response.body);
    final memories = (data['memories'] as List?)
            ?.map((m) => Memory.fromJson(m))
            .toList() ??
        [];
    debugPrint('[Memories] Search found ${memories.length} memories');
    return memories;
  } catch (e) {
    debugPrint('[Memories] Error parsing search results: $e');
    return [];
  }
}

/// Edit memory content (legacy API compatibility)
Future<bool> editMemoryServer(String memoryId, String value) async {
  final result = await updateMemoryServer(memoryId: memoryId, content: value);
  return result != null;
}

/// Delete all memories (not implemented in new API - returns false)
Future<bool> deleteAllMemoriesServer() async {
  debugPrint('[Memories] deleteAllMemories not supported in new API');
  return false;
}
