import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/recovery_session.dart';
import 'package:path_provider/path_provider.dart';

/// Service for persisting transcript segments incrementally to enable recovery
/// after app crashes or unexpected termination.
///
/// Segments are saved to a JSON file and can be recovered on app restart.
class TranscriptRecoveryService {
  static const String _fileName = 'transcript_recovery.json';

  /// Get the recovery file path
  static Future<File> _getRecoveryFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_fileName');
  }

  /// Save segments incrementally (should be called with debouncing)
  ///
  /// This saves the current state of segments to disk so they can be
  /// recovered if the app crashes or is killed by the OS.
  static Future<void> saveSegments({
    required String sessionId,
    required DateTime startedAt,
    required List<TranscriptSegment> segments,
  }) async {
    if (segments.isEmpty) {
      debugPrint('[TranscriptRecovery] No segments to save');
      return;
    }

    try {
      final file = await _getRecoveryFile();
      final session = RecoverySession(
        sessionId: sessionId,
        startedAt: startedAt,
        lastUpdatedAt: DateTime.now(),
        segments: segments,
      );

      await file.writeAsString(jsonEncode(session.toJson()));
      debugPrint('[TranscriptRecovery] Saved ${segments.length} segments for session $sessionId');
    } catch (e) {
      debugPrint('[TranscriptRecovery] Error saving segments: $e');
    }
  }

  /// Check if there's an interrupted session that can be recovered
  ///
  /// Returns the recovery session if one exists and has enough content,
  /// otherwise returns null.
  static Future<RecoverySession?> checkForInterruptedSession() async {
    try {
      final file = await _getRecoveryFile();

      if (!await file.exists()) {
        debugPrint('[TranscriptRecovery] No recovery file found');
        return null;
      }

      final content = await file.readAsString();
      if (content.isEmpty) {
        debugPrint('[TranscriptRecovery] Recovery file is empty');
        await file.delete();
        return null;
      }

      final json = jsonDecode(content) as Map<String, dynamic>;
      final session = RecoverySession.fromJson(json);

      debugPrint('[TranscriptRecovery] Found interrupted session: $session');

      // Check if session is worth recovering
      if (!session.isWorthRecovering) {
        debugPrint('[TranscriptRecovery] Session not worth recovering, clearing');
        await file.delete();
        return null;
      }

      // Check if session is too old (more than 24 hours)
      final age = DateTime.now().difference(session.lastUpdatedAt);
      if (age.inHours > 24) {
        debugPrint('[TranscriptRecovery] Session too old (${age.inHours}h), clearing');
        await file.delete();
        return null;
      }

      return session;
    } catch (e) {
      debugPrint('[TranscriptRecovery] Error checking for interrupted session: $e');
      // Clear corrupted file
      try {
        final file = await _getRecoveryFile();
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
      return null;
    }
  }

  /// Clear recovery data after successful save
  ///
  /// This should be called after the conversation has been successfully
  /// saved to the database.
  static Future<void> clearRecoveryData() async {
    try {
      final file = await _getRecoveryFile();
      if (await file.exists()) {
        await file.delete();
        debugPrint('[TranscriptRecovery] Cleared recovery data');
      }
    } catch (e) {
      debugPrint('[TranscriptRecovery] Error clearing recovery data: $e');
    }
  }

  /// Check if a recovery file exists (quick check without parsing)
  static Future<bool> hasRecoveryData() async {
    try {
      final file = await _getRecoveryFile();
      return await file.exists();
    } catch (e) {
      return false;
    }
  }
}
