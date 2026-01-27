import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/schema.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/supabase_auth_service.dart';

Future<ActionItemsResponse> getActionItems({
  int limit = 50,
  int offset = 0,
  bool? completed,
  String? conversationId,
  DateTime? startDate,
  DateTime? endDate,
}) async {
  final userId = SupabaseAuthService.instance.maityUserId;
  if (userId == null) {
    debugPrint('[getActionItems] No maityUserId available');
    return ActionItemsResponse(actionItems: [], hasMore: false);
  }

  // Build query parameters
  var params = 'user_id=$userId&limit=$limit&offset=$offset';
  if (completed != null) {
    params += '&completed=$completed';
  }

  var response = await makeApiCall(
    url: '${Env.maityBackendUrl}/v1/action-items/from-conversations?$params',
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null) {
    debugPrint('[getActionItems] No response from API');
    return ActionItemsResponse(actionItems: [], hasMore: false);
  }

  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    var data = jsonDecode(body);
    return ActionItemsResponse(
      actionItems: (data['action_items'] as List<dynamic>)
          .map((item) => ActionItemWithMetadata.fromJson(item))
          .toList(),
      hasMore: data['has_more'] ?? false,
    );
  } else {
    debugPrint('[getActionItems] Error ${response.statusCode}: ${response.body}');
    return ActionItemsResponse(actionItems: [], hasMore: false);
  }
}

Future<ActionItemWithMetadata?> getActionItem(String actionItemId) async {
  final userId = SupabaseAuthService.instance.maityUserId;
  if (userId == null) return null;

  var response = await makeApiCall(
    url: '${Env.maityBackendUrl}/v1/action-items/$actionItemId?user_id=$userId',
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null) return null;

  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    return ActionItemWithMetadata.fromJson(jsonDecode(body));
  } else {
    debugPrint('getActionItem error ${response.statusCode}');
    return null;
  }
}

Future<ActionItemWithMetadata?> createActionItem({
  required String description,
  DateTime? dueAt,
  String? conversationId,
  bool completed = false,
}) async {
  final userId = SupabaseAuthService.instance.maityUserId;
  if (userId == null) return null;

  var requestBody = {
    'description': description,
    'completed': completed,
  };

  if (dueAt != null) {
    requestBody['due_at'] = dueAt.toUtc().toIso8601String();
  }
  if (conversationId != null) {
    requestBody['conversation_id'] = conversationId;
  }

  var response = await makeApiCall(
    url: '${Env.maityBackendUrl}/v1/action-items?user_id=$userId',
    headers: {},
    method: 'POST',
    body: jsonEncode(requestBody),
  );

  if (response == null) return null;

  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    return ActionItemWithMetadata.fromJson(jsonDecode(body));
  } else {
    debugPrint('createActionItem error ${response.statusCode}');
    return null;
  }
}

Future<ActionItemWithMetadata?> updateActionItem(
  String actionItemId, {
  String? description,
  bool? completed,
  DateTime? dueAt,
  bool? exported,
  DateTime? exportDate,
  String? exportPlatform,
}) async {
  final userId = SupabaseAuthService.instance.maityUserId;
  if (userId == null) return null;

  var requestBody = <String, dynamic>{};

  if (description != null) {
    requestBody['description'] = description;
  }
  if (completed != null) {
    requestBody['completed'] = completed;
  }
  if (dueAt != null) {
    requestBody['due_at'] = dueAt.toUtc().toIso8601String();
  }

  var response = await makeApiCall(
    url: '${Env.maityBackendUrl}/v1/action-items/$actionItemId?user_id=$userId',
    headers: {},
    method: 'PATCH',
    body: jsonEncode(requestBody),
  );

  if (response == null) return null;

  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    return ActionItemWithMetadata.fromJson(jsonDecode(body));
  } else {
    debugPrint('updateActionItem error ${response.statusCode}');
    return null;
  }
}

Future<ActionItemWithMetadata?> toggleActionItemCompletion(
  String actionItemId,
  bool completed,
) async {
  return updateActionItem(actionItemId, completed: completed);
}

Future<bool> deleteActionItem(String actionItemId) async {
  final userId = SupabaseAuthService.instance.maityUserId;
  if (userId == null) return false;

  var response = await makeApiCall(
    url: '${Env.maityBackendUrl}/v1/action-items/$actionItemId?user_id=$userId',
    headers: {},
    method: 'DELETE',
    body: '',
  );

  if (response == null) return false;

  return response.statusCode == 200;
}

// Conversation-specific action items
Future<ActionItemsResponse> getConversationActionItems(String conversationId) async {
  final userId = SupabaseAuthService.instance.maityUserId;
  if (userId == null) return ActionItemsResponse(actionItems: [], hasMore: false);

  // Use the from-conversations endpoint with all items, then filter by conversationId
  var response = await makeApiCall(
    url: '${Env.maityBackendUrl}/v1/action-items/from-conversations?user_id=$userId&limit=500',
    headers: {},
    method: 'GET',
    body: '',
  );

  if (response == null) return ActionItemsResponse(actionItems: [], hasMore: false);

  if (response.statusCode == 200) {
    var body = utf8.decode(response.bodyBytes);
    var data = jsonDecode(body);
    var allItems = (data['action_items'] as List<dynamic>)
        .map((item) => ActionItemWithMetadata.fromJson(item))
        .where((item) => item.conversationId == conversationId)
        .toList();

    return ActionItemsResponse(
      actionItems: allItems,
      hasMore: false,
    );
  } else {
    debugPrint('getConversationActionItems error ${response.statusCode}');
    return ActionItemsResponse(actionItems: [], hasMore: false);
  }
}

Future<bool> deleteConversationActionItems(String conversationId) async {
  // This would need to delete all action items for a conversation
  // For now, not implemented as it requires backend support
  debugPrint('[deleteConversationActionItems] Not implemented');
  return false;
}

// Batch operations
Future<List<ActionItemWithMetadata>> createActionItemsBatch(
  List<Map<String, dynamic>> actionItems,
) async {
  // Batch creation not yet implemented for Supabase backend
  debugPrint('[createActionItemsBatch] Not implemented');
  return [];
}
