import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/recovery_session.dart';
import 'package:omi/services/background_upload_service.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/conversation_processor.dart';
import 'package:omi/services/recording/telemetry_collector.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/services/transcript_recovery_service.dart';
import 'package:omi/services/stt/local/chunk_queue_manager.dart';
import 'package:omi/services/recording/wav_gap_recovery.dart';
import 'package:omi/utils/mutex.dart';
import 'package:path_provider/path_provider.dart';

/// Manages all data persistence during a recording session.
///
/// Responsibilities:
/// - Local recovery file writes (atomic temp+rename)
/// - Finalization with mutex protection (prevents race conditions)
/// - Queue conversation for background upload via BackgroundUploadService
class PersistenceManager {
  CaptureLogService get _captureLog => CaptureLogService.instance;

  // --- Finalize mutex (C2: prevents race condition) ---
  final Mutex _finalizeMutex = Mutex();

  // --- Cached directory for synchronous saves ---
  String? _cachedDocumentsPath;

  // --- Recovery state ---
  Timer? _recoveryTimer;
  int _unsavedSegmentCount = 0;

  // --- Recovery threshold (M1: 20 words instead of 5) ---
  static const int _recoveryMinWords = 20;
  static const int _recoveryMinDurationSeconds = 15;

  // ---------------------------------------------------------------------------
  // Local Save (Recovery)
  // ---------------------------------------------------------------------------

  /// Schedules a local save with debouncing.
  /// Saves every 5 seconds or after 15 new segments, whichever comes first.
  /// Saves immediately on the first segment to prevent data loss on early crash.
  void scheduleLocalSave(
    List<TranscriptSegment> segments,
    String? sessionId,
    DateTime? startedAt,
    bool isSpeechProfileMode,
  ) {
    if (isSpeechProfileMode) return;

    _unsavedSegmentCount++;

    // Save immediately on the FIRST segment
    if (segments.length <= 1) {
      saveRecoveryData(segments, sessionId ?? '', startedAt ?? DateTime.now());
      return;
    }

    // Save immediately if 15+ unsaved segments
    if (_unsavedSegmentCount >= 15) {
      saveRecoveryData(segments, sessionId ?? '', startedAt ?? DateTime.now());
      return;
    }

    // Otherwise, debounce to every 5 seconds
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(const Duration(seconds: 5), () {
      saveRecoveryData(segments, sessionId ?? '', startedAt ?? DateTime.now());
    });
  }

  /// Saves current segments to recovery file using atomic write (C4).
  Future<void> saveRecoveryData(
    List<TranscriptSegment> segments,
    String sessionId,
    DateTime startedAt, {
    bool synchronous = false,
  }) async {
    if (segments.isEmpty) return;

    try {
      final segmentsCopy = List<TranscriptSegment>.from(segments);

      await _atomicSaveRecovery(
        sessionId: sessionId,
        startedAt: startedAt,
        segments: segmentsCopy,
        synchronous: synchronous,
      );

      _captureLog.log('recovery', 'recovery_data_saved', severity: 'debug', details: {
        'segments_count': segmentsCopy.length,
      });
      _unsavedSegmentCount = 0;
    } catch (e) {
      debugPrint('[PersistenceManager] Error saving recovery data: $e');
      _captureLog.log('recovery', 'recovery_save_failed', severity: 'error', details: {
        'error': e.toString(),
      });
    }
  }

  /// C4: Atomic JSON write — temp file + rename to prevent corruption.
  Future<void> _atomicSaveRecovery({
    required String sessionId,
    required DateTime startedAt,
    required List<TranscriptSegment> segments,
    bool synchronous = false,
  }) async {
    final String dirPath;
    if (synchronous && _cachedDocumentsPath != null) {
      dirPath = _cachedDocumentsPath!;
    } else {
      final directory = await getApplicationDocumentsDirectory();
      dirPath = directory.path;
      _cachedDocumentsPath = dirPath;
    }
    final targetFile = File('$dirPath/transcript_recovery.json');
    final tempFile = File('$dirPath/transcript_recovery.json.tmp');

    final segmentMaps = segments.map((s) => s.toJson()).toList();
    final now = DateTime.now().toIso8601String();
    final startedAtStr = startedAt.toIso8601String();

    if (synchronous) {
      // Use sync I/O to guarantee completion before iOS suspends the app
      final json = <String, dynamic>{
        'session_id': sessionId,
        'started_at': startedAtStr,
        'last_updated_at': now,
        'segments': segmentMaps,
      };
      final jsonString = jsonEncode(json);
      tempFile.writeAsStringSync(jsonString);
      if (Platform.isWindows && targetFile.existsSync()) {
        targetFile.deleteSync();
      }
      tempFile.renameSync(targetFile.path);
      return;
    }

    final payload = <String, dynamic>{
      'session_id': sessionId,
      'started_at': startedAtStr,
      'last_updated_at': now,
      'segments': segmentMaps,
    };
    final jsonString = await compute(_encodeJsonMap, payload);
    await tempFile.writeAsString(jsonString);

    // Windows: File.rename fails if target exists (unlike POSIX atomic rename)
    if (Platform.isWindows && await targetFile.exists()) {
      await targetFile.delete();
    }
    await tempFile.rename(targetFile.path);
  }

  static String _encodeJsonMap(Map<String, dynamic> data) {
    return jsonEncode(data);
  }

  /// Clears recovery data and resets recovery state.
  Future<void> clearRecoveryState() async {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _unsavedSegmentCount = 0;
    try {
      await TranscriptRecoveryService.clearRecoveryData();
    } catch (e) {
      debugPrint('[PersistenceManager] Error clearing recovery state: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Finalize Conversation (C2: Mutex)
  // ---------------------------------------------------------------------------

  /// Finalizes a recording session: processes locally, queues for background
  /// upload, and clears recovery state.
  ///
  /// Uses a [Mutex] (C2) to prevent concurrent finalize calls.
  /// Returns true if the conversation was successfully queued for upload.
  Future<bool> finalizeConversation({
    required List<TranscriptSegment> segments,
    required String? userId,
    required DateTime? startedAt,
    required bool isSpeechProfileMode,
    required Function() onSuccess,
    String? sessionId,
  }) async {
    if (isSpeechProfileMode) {
      debugPrint('[PersistenceManager] SKIP: Speech profile mode active');
      return false;
    }

    if (segments.isEmpty) {
      debugPrint('[PersistenceManager] SKIP: No segments to save');
      await clearRecoveryState();
      return false;
    }

    // C2: Mutex instead of bool flag — prevents race condition
    await _finalizeMutex.acquire();
    try {
      return await _doFinalize(
        segments: segments,
        userId: userId,
        startedAt: startedAt,
        onSuccess: onSuccess,
        sessionId: sessionId,
      );
    } finally {
      _finalizeMutex.release();
    }
  }

  /// Internal finalize logic. Called under mutex protection.
  Future<bool> _doFinalize({
    required List<TranscriptSegment> segments,
    required String? userId,
    required DateTime? startedAt,
    required Function() onSuccess,
    String? sessionId,
  }) async {
    final localSegments = List<TranscriptSegment>.from(segments);
    final transcript = localSegments.map((s) => s.text).join('\n').trim();
    final effectiveStartedAt = startedAt ?? DateTime.now();
    final finishedAt = DateTime.now();

    _captureLog.log('save', 'finalize_started', details: {
      'segments_count': localSegments.length,
      'transcript_length': transcript.length,
    });

    debugPrint('[PersistenceManager] START: ${localSegments.length} segments, '
        'transcript=${transcript.length} chars');

    // Cancel recovery timer (don't clear data yet — only after successful queue)
    _recoveryTimer?.cancel();

    // Resolve userId if null — use cached getter first (no network),
    // only fetch actively when online to avoid 7s retry delay offline.
    var effectiveUserId = userId;
    if (effectiveUserId == null) {
      effectiveUserId = SupabaseAuthService.instance.maityUserId;
      if (effectiveUserId == null && ConnectivityService().isConnected) {
        debugPrint('[PersistenceManager] userId null, attempting fetch...');
        effectiveUserId =
            await SupabaseAuthService.instance.fetchMaityUserId();
      }
    }
    debugPrint('[PersistenceManager] userId=$effectiveUserId');

    try {
      // Process locally if transcript is short enough
      Map<String, dynamic>? structuredData;
      if (transcript.length <= 6000) {
        debugPrint('[PersistenceManager] Processing locally (${transcript.length} chars)...');
        final structured = await ConversationProcessor.processLocally(localSegments);
        if (structured != null) {
          structuredData = {
            'title': structured.title,
            'overview': structured.overview,
            'emoji': structured.emoji,
            'category': structured.category,
            'discarded': structured.discarded,
            'action_items': structured.actionItems.map((a) => a.toJson()).toList(),
            'events': structured.events.map((e) => e.toJson()).toList(),
          };
          debugPrint('[PersistenceManager] Local result: title="${structured.title}"');
        }
      } else {
        debugPrint('[PersistenceManager] Long transcript (${transcript.length} chars), backend will process');
      }

      // Detect transcript gaps for diagnostics
      if (localSegments.length >= 2) {
        final recordingDuration =
            finishedAt.difference(effectiveStartedAt).inSeconds.toDouble();
        final gaps = WavGapRecovery.detectGaps(
            localSegments, recordingDuration);
        if (gaps.isNotEmpty) {
          final totalGap = gaps.fold<double>(0, (sum, g) => sum + g.duration);
          debugPrint('[PersistenceManager] Detected ${gaps.length} transcript gaps '
              '(total: ${totalGap.toStringAsFixed(1)}s): $gaps');
        }
      }

      // Capture telemetry snapshot now (after stop time has been recorded
      // by CaptureProvider). Word count is derived from the segments we
      // are about to upload.
      final telemetryWords = localSegments.fold<int>(
          0, (sum, s) => sum + s.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length);
      TelemetryCollector.instance.updateSegmentMetrics(
        segmentsCount: localSegments.length,
        wordsCount: telemetryWords,
      );
      final telemetrySnapshot = TelemetryCollector.instance.snapshot();

      // Queue for background upload
      await BackgroundUploadService.instance.enqueue(
        segments: localSegments,
        startedAt: effectiveStartedAt,
        finishedAt: finishedAt,
        userId: effectiveUserId,
        source: 'omi',
        structured: structuredData,
        telemetry: telemetrySnapshot,
      );

      // Reset collector now that the snapshot has been handed off to the
      // upload queue. The next session can begin with clean state.
      TelemetryCollector.instance.reset();

      _captureLog.log('save', 'finalize_queued_for_upload', details: {
        'segments_count': localSegments.length,
        'has_structured': structuredData != null,
      });
      debugPrint('[PersistenceManager] SUCCESS: queued for background upload');

      // Mark chunk session as finalized (chunks can be cleaned up after upload)
      if (sessionId != null) {
        await ChunkQueueManager.instance.markSessionFinalized(sessionId);
      }

      // Clear recovery state only after successful queue
      await clearRecoveryState();
      onSuccess();
      return true;
    } catch (e, stackTrace) {
      _captureLog.log('save', 'finalize_error', severity: 'error', details: {
        'error': e.toString(),
      });
      debugPrint('[PersistenceManager] ERROR: $e');
      debugPrint('[PersistenceManager] Stack trace: $stackTrace');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Recover Interrupted Session
  // ---------------------------------------------------------------------------

  /// Recovers an interrupted session from recovery data.
  /// Returns true if recovery was successful.
  Future<bool> recoverInterruptedSession(
    List<TranscriptSegment> recoverySegments,
    DateTime startedAt, {
    String? draftConversationId,
    required Function(dynamic) onConversationSaved,
    required Function() onConversationsRefreshed,
  }) async {
    if (recoverySegments.isEmpty) {
      debugPrint('[PersistenceManager] No segments to recover');
      await TranscriptRecoveryService.clearRecoveryData();
      return false;
    }

    _captureLog.log('recovery', 'recovery_attempted', details: {
      'segments_count': recoverySegments.length,
    });
    debugPrint('[PersistenceManager] Recovering ${recoverySegments.length} segments');

    try {
      final userId = SupabaseAuthService.instance.maityUserId;

      // Process locally for structured data
      Map<String, dynamic>? structuredData;
      final structured = await ConversationProcessor.processLocally(recoverySegments);
      if (structured != null) {
        structuredData = {
          'title': structured.title,
          'overview': structured.overview,
          'emoji': structured.emoji,
          'category': structured.category,
          'discarded': structured.discarded,
          'action_items': structured.actionItems.map((a) => a.toJson()).toList(),
          'events': structured.events.map((e) => e.toJson()).toList(),
        };
      }

      // Build a minimal recovery telemetry snapshot. We don't have the
      // original session's reconnection/error counters, but we can capture
      // segment counts and the recovered duration so the dashboard can
      // surface it under outcome='recovered'.
      final recoveryDurationSec =
          DateTime.now().difference(startedAt).inSeconds;
      final recoveryWords = recoverySegments.fold<int>(
          0,
          (sum, s) =>
              sum + s.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length);
      final recoveryTelemetry = <String, dynamic>{
        'session_id': null,
        'duration_seconds': recoveryDurationSec,
        'segments_count': recoverySegments.length,
        'words_count': recoveryWords,
        'audio_source': null,
        'device_model': null,
        'stt_provider': null,
        'reconnection_count': 0,
        'audio_gaps_seconds': 0,
        'ble_disconnects': 0,
        'errors_count': 0,
        'app_version': null,
        'os_version': null,
        'platform': 'unknown',
        // Tag this snapshot so a successful upload is reported as 'recovered'
        // instead of 'completed'. _sendTelemetry honors this hint.
        '_success_outcome': 'recovered',
        'raw_metrics': {'source': 'recovery'},
      };

      // Queue for background upload
      await BackgroundUploadService.instance.enqueue(
        segments: recoverySegments,
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        userId: userId,
        structured: structuredData,
        telemetry: recoveryTelemetry,
      );

      debugPrint('[PersistenceManager] Recovery queued for background upload');
      _captureLog.log('recovery', 'recovery_queued', details: {
        'segments_count': recoverySegments.length,
      });

      onConversationsRefreshed();
      await TranscriptRecoveryService.clearRecoveryData();
      return true;
    } catch (e) {
      _captureLog.log('recovery', 'recovery_failed', severity: 'error', details: {
        'error': e.toString(),
      });
      debugPrint('[PersistenceManager] Error recovering session: $e');
      return false;
    }
  }

  /// M1: Stricter recovery threshold — 20 words AND 15 seconds minimum.
  bool isWorthRecovering(RecoverySession session) {
    if (session.segments.isEmpty) return false;

    if (session.wordCount < _recoveryMinWords &&
        session.estimatedDuration.inSeconds < _recoveryMinDurationSeconds) {
      debugPrint('[PersistenceManager] Session not worth recovering: '
          '${session.wordCount} words, ${session.estimatedDuration.inSeconds}s '
          '(min: $_recoveryMinWords words or ${_recoveryMinDurationSeconds}s)');
      return false;
    }

    return true;
  }

  // ---------------------------------------------------------------------------
  // Force Finalize
  // ---------------------------------------------------------------------------

  /// Forces finalization and then resets state.
  Future<bool> forceFinalize({
    required List<TranscriptSegment> segments,
    required String? userId,
    required DateTime? startedAt,
    required bool isSpeechProfileMode,
    required Function() onSuccess,
  }) async {
    final result = await finalizeConversation(
      segments: segments,
      userId: userId,
      startedAt: startedAt,
      isSpeechProfileMode: isSpeechProfileMode,
      onSuccess: onSuccess,
    );
    reset();
    return result;
  }

  // ---------------------------------------------------------------------------
  // Reset / Dispose
  // ---------------------------------------------------------------------------

  /// Resets all persistence state for a new recording session.
  void reset() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _unsavedSegmentCount = 0;
  }

  /// Async reset that waits for any in-progress finalize to complete (C3).
  Future<void> resetAsync() async {
    await _finalizeMutex.acquire();
    try {
      reset();
    } finally {
      _finalizeMutex.release();
    }
  }

  /// Disposes timers and resources.
  void dispose() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
  }
}
