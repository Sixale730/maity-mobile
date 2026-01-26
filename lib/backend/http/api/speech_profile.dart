import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/services/voice_profile_service.dart';

Future<bool> userHasSpeakerProfile() async {
  // Check voice profile status from our Supabase backend
  final userId = SupabaseAuthService.instance.maityUserId;
  if (userId == null) {
    debugPrint('[userHasSpeakerProfile] No maityUserId - user not authenticated');
    return false;
  }

  try {
    final status = await VoiceProfileService.getProfileStatus(userId);
    debugPrint('[userHasSpeakerProfile] User $userId hasProfile: ${status.hasProfile}');
    return status.hasProfile;
  } catch (e) {
    debugPrint('[userHasSpeakerProfile] Error checking profile status: $e');
    return false;
  }
}

Future<String?> getUserSpeechProfile() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v4/speech-profile',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return null;
  debugPrint('userHasSpeakerProfile: ${response.body}');
  if (response.statusCode == 200) return jsonDecode(response.body)['url'];
  return null;
}

Future<bool> uploadProfile(File file) async {
  try {
    var response = await makeMultipartApiCall(
      url: '${Env.apiBaseUrl}v3/upload-audio',
      files: [file],
      fileFieldName: 'file',
    );

    if (response.statusCode == 200) {
      debugPrint('uploadProfile Response body: ${jsonDecode(response.body)}');
      return true;
    } else {
      debugPrint('Failed to upload sample. Status code: ${response.statusCode}');
      throw Exception('Failed to upload sample. Status code: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('An error occurred uploadSample: $e');
    throw Exception('An error occurred uploadSample: $e');
  }
}

Future<List<String>> getExpandedProfileSamples() async {
  var response = await makeApiCall(
    url: '${Env.apiBaseUrl}v3/speech-profile/expand',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return [];
  debugPrint('getExpandedProfileSamples: ${response.body}');
  if (response.statusCode == 200) {
    var data = jsonDecode(response.body);
    if (data != null) {
      return List<String>.from(data);
    }
  }
  return [];
}

Future<bool> deleteProfileSample(
  String conversationId,
  int segmentIdx, {
  String? personId,
}) async {
  var response = await makeApiCall(
    url:
        '${Env.apiBaseUrl}v3/speech-profile/expand?memory_id=$conversationId&segment_idx=$segmentIdx&person_id=$personId',
    headers: {},
    method: 'DELETE',
    body: '',
  );
  if (response == null) return false;
  debugPrint('deleteProfileSample: ${response.body}');
  if (response.statusCode == 200) return true;
  return false;
}
