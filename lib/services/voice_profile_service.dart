import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';

/// Service for voice profile enrollment and verification
/// Uses Modal.com backend for ECAPA-TDNN embeddings (192 dimensions)
class VoiceProfileService {
  static String get _baseUrl => Env.maityBackendUrl ?? 'https://maity-mobile.vercel.app';
  static const Duration _enrollTimeout = Duration(seconds: 120);
  static const Duration _verifyTimeout = Duration(seconds: 180);
  static const Duration _statusTimeout = Duration(seconds: 10);

  /// Enrolls user's voice profile from a WAV file
  /// [userId] is the UUID from maity.users
  /// [audioFile] should be WAV format, 16kHz, mono, 16-bit PCM
  /// Returns true if enrollment was successful
  static Future<bool> enrollVoiceProfile({
    required String userId,
    required File audioFile,
  }) async {
    try {
      debugPrint('[VoiceProfile] Enrolling voice for user $userId');
      debugPrint('[VoiceProfile] Audio file: ${audioFile.path}');

      final authHeader = await getAuthHeader();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/v1/voice/enroll'),
      );

      request.headers['Authorization'] = authHeader;
      request.fields['user_id'] = userId;
      request.files.add(
        await http.MultipartFile.fromPath(
          'audio',
          audioFile.path,
          contentType: MediaType('audio', 'wav'),
        ),
      );

      final streamedResponse = await request.send().timeout(_enrollTimeout);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('[VoiceProfile] Enrollment success: ${data['message']}');
        return data['success'] == true;
      } else {
        debugPrint('[VoiceProfile] Enrollment failed: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('[VoiceProfile] Enrollment error: $e');
      return false;
    }
  }

  /// Enrolls user's voice profile from raw audio bytes
  /// [audioBytes] should be PCM 16-bit, 16kHz, mono
  /// Returns true if enrollment was successful
  static Future<bool> enrollVoiceProfileFromBytes({
    required String userId,
    required Uint8List audioBytes,
    int sampleRate = 16000,
  }) async {
    try {
      debugPrint('[VoiceProfile] Enrolling voice from bytes for user $userId');
      debugPrint('[VoiceProfile] Audio size: ${audioBytes.length} bytes');

      final authHeader = await getAuthHeader();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/v1/voice/enroll'),
      );

      request.headers['Authorization'] = authHeader;
      request.fields['user_id'] = userId;
      request.files.add(
        http.MultipartFile.fromBytes(
          'audio',
          audioBytes,
          filename: 'voice_profile.wav',
          contentType: MediaType('audio', 'wav'),
        ),
      );

      final streamedResponse = await request.send().timeout(_enrollTimeout);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('[VoiceProfile] Enrollment success: ${data['message']}');
        return data['success'] == true;
      } else {
        debugPrint('[VoiceProfile] Enrollment failed: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('[VoiceProfile] Enrollment error: $e');
      return false;
    }
  }

  /// Verifies multiple speakers against user's voice profile
  /// [speakerAudioSegments] maps speaker_id (int) to their audio bytes (PCM 16-bit)
  /// Returns map of speaker_id -> verification result
  static Future<Map<String, SpeakerVerificationResult>> verifySpeakers({
    required String userId,
    required Map<int, Uint8List> speakerAudioSegments,
    int sampleRate = 16000,
    double threshold = 0.75,
  }) async {
    if (speakerAudioSegments.isEmpty) {
      debugPrint('[VoiceProfile] No speaker segments to verify');
      return {};
    }

    try {
      debugPrint('[VoiceProfile] Verifying ${speakerAudioSegments.length} speakers for user $userId');

      // Convert audio bytes to base64
      final speakerSegmentsBase64 = <String, String>{};
      for (final entry in speakerAudioSegments.entries) {
        speakerSegmentsBase64[entry.key.toString()] = base64Encode(entry.value);
        debugPrint('[VoiceProfile] Speaker ${entry.key}: ${entry.value.length} bytes');
      }

      final authHeader = await getAuthHeader();
      final response = await http
          .post(
            Uri.parse('$_baseUrl/v1/voice/verify-speakers'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': authHeader,
            },
            body: jsonEncode({
              'user_id': userId,
              'speaker_segments': speakerSegmentsBase64,
              'sample_rate': sampleRate,
              'threshold': threshold,
            }),
          )
          .timeout(_verifyTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = <String, SpeakerVerificationResult>{};

        final resultsMap = data['results'] as Map<String, dynamic>?;
        if (resultsMap != null) {
          for (final entry in resultsMap.entries) {
            results[entry.key] = SpeakerVerificationResult.fromJson(entry.value as Map<String, dynamic>);
          }
        }

        debugPrint('[VoiceProfile] Verification complete: $results');
        return results;
      }

      debugPrint('[VoiceProfile] Verification failed: ${response.statusCode} - ${response.body}');
      return {};
    } catch (e) {
      debugPrint('[VoiceProfile] Verification error: $e');
      return {};
    }
  }

  /// Checks if user has an active voice profile
  static Future<VoiceProfileStatus> getProfileStatus(String userId) async {
    try {
      final authHeader = await getAuthHeader();
      final response = await http
          .get(
            Uri.parse('$_baseUrl/v1/voice/status?user_id=$userId'),
            headers: {'Authorization': authHeader},
          )
          .timeout(_statusTimeout);

      if (response.statusCode == 200) {
        return VoiceProfileStatus.fromJson(jsonDecode(response.body));
      }
      return VoiceProfileStatus(hasProfile: false);
    } catch (e) {
      debugPrint('[VoiceProfile] Status check error: $e');
      return VoiceProfileStatus(hasProfile: false);
    }
  }

  /// Deletes user's voice profile
  static Future<bool> deleteProfile(String userId) async {
    try {
      final authHeader = await getAuthHeader();
      final response = await http
          .delete(
            Uri.parse('$_baseUrl/v1/voice/profile?user_id=$userId'),
            headers: {'Authorization': authHeader},
          )
          .timeout(_statusTimeout);

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[VoiceProfile] Delete error: $e');
      return false;
    }
  }
}

/// Result of speaker verification against user's voice profile
class SpeakerVerificationResult {
  final bool isUser;
  final double similarity;
  final String? error;

  SpeakerVerificationResult({
    required this.isUser,
    required this.similarity,
    this.error,
  });

  factory SpeakerVerificationResult.fromJson(Map<String, dynamic> json) {
    return SpeakerVerificationResult(
      isUser: json['is_user'] ?? false,
      similarity: (json['similarity'] as num?)?.toDouble() ?? 0.0,
      error: json['error'] as String?,
    );
  }

  @override
  String toString() =>
      'SpeakerVerificationResult(isUser: $isUser, similarity: ${similarity.toStringAsFixed(2)}, error: $error)';
}

/// Status of user's voice profile
class VoiceProfileStatus {
  final bool hasProfile;
  final DateTime? createdAt;
  final double? qualityScore;

  VoiceProfileStatus({
    required this.hasProfile,
    this.createdAt,
    this.qualityScore,
  });

  factory VoiceProfileStatus.fromJson(Map<String, dynamic> json) {
    return VoiceProfileStatus(
      hasProfile: json['has_profile'] ?? false,
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at']) : null,
      qualityScore: (json['quality_score'] as num?)?.toDouble(),
    );
  }

  @override
  String toString() =>
      'VoiceProfileStatus(hasProfile: $hasProfile, createdAt: $createdAt, qualityScore: $qualityScore)';
}
