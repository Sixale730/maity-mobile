import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/recovery_session.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/conversation_processor.dart';
import 'package:omi/services/incremental_save_service.dart';
import 'package:omi/services/local_conversations_service.dart';
import 'package:omi/services/omi_supabase_service.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/services/transcript_recovery_service.dart';
import 'package:omi/utils/mutex.dart';
import 'package:path_provider/path_provider.dart';

/// Manages all data persistence during a recording session.
///
/// Responsibilities:
/// - Incremental segment saves to Supabase (draft + append)
/// - Recovery file writes (atomic temp+rename)
/// - Finalization with mutex protection (prevents race conditions)
/// - Orphan draft cleanup
/// - Segment trimming for long recordings
class PersistenceManager {
  CaptureLogService get _captureLog => CaptureLogService.instance;

  // --- Finalize mutex (C2: prevents race condition) ---
  final Mutex _finalizeMutex = Mutex();

  // --- Incremental save ---
  final IncrementalSaveService _incrementalSave = IncrementalSaveService();

  // --- Recovery state ---
  Timer? _recoveryTimer;
  int _unsavedSegmentCount = 0;

  // --- Segment trimming ---
  static const int _maxSegmentsInMemory = 200;
  int _totalSegmentCount = 0;
  int get totalSegmentCount => _totalSegmentCount;

  // --- Concurrent flush guard (H8) ---
  Completer<void>? _saveInFlight;

  // --- Draft creation guard (prevents concurrent ensureDraftCreated calls) ---
  Completer<void>? _draftCreationInFlight;

  // --- Recovery threshold (M1: 20 words instead of 5) ---
  static const int _recoveryMinWords = 20;
  static const int _recoveryMinDurationSeconds = 15;

  // --- Public access to incremental save state ---
  String? get draftId => _incrementalSave.draftId;
  int get savedSegmentCount => _incrementalSave.savedSegmentCount;

  /// Notifies the manager that new segments have been produced.
  /// Call this from the transcription pipeline after merging segments.
  void onSegmentsUpdated(int newSegmentCount) {
    _totalSegmentCount += newSegmentCount;
  }

  // ---------------------------------------------------------------------------
  // Incremental Save
  // ---------------------------------------------------------------------------

  /// Schedules incremental save of segments to Supabase.
  /// Guards: skips if speech profile mode, no userId, or no segments.
  Future<void> scheduleIncrementalSave(
    List<TranscriptSegment> segments,
    String? userId,
    DateTime? startedAt,
    bool isSpeechProfileMode,
  ) async {
    if (isSpeechProfileMode) return;
    if (userId == null || userId.isEmpty) {
      assert(() { debugPrint('[PersistenceManager] WARNING: userId null during incremental save'); return true; }());
      _captureLog.log('save', 'skipped_no_user_id', severity: 'warning');
      return;
    }

    // C5: Ensure draft is created on first segment; guard against concurrent calls
    if (_incrementalSave.draftId == null && segments.isNotEmpty) {
      // If another call is already creating the draft, wait for it instead of duplicating
      if (_draftCreationInFlight != null && !_draftCreationInFlight!.isCompleted) {
        await _draftCreationInFlight!.future;
      } else {
        _draftCreationInFlight = Completer<void>();
        try {
          await _incrementalSave.ensureDraftCreated(
            userId: userId,
            startedAt: startedAt ?? DateTime.now(),
          );
        } catch (e) {
          _captureLog.log('save', 'draft_creation_failed', severity: 'error', details: {
            'error': e.toString(),
          });
          debugPrint('[PersistenceManager] Draft creation failed: $e');
          return;
        } finally {
          if (_draftCreationInFlight != null && !_draftCreationInFlight!.isCompleted) {
            _draftCreationInFlight!.complete();
          }
          _draftCreationInFlight = null;
        }
        if (_incrementalSave.draftId != null) {
          _captureLog.log('save', 'draft_created', details: {
            'draft_id': _incrementalSave.draftId,
          });
          _captureLog.updateConversationId(_incrementalSave.draftId!);
        } else {
          _captureLog.log('save', 'draft_creation_null', severity: 'error', details: {
            'error': 'ensureDraftCreated returned null without throwing',
          });
          assert(() { debugPrint('[PersistenceManager] Draft creation returned null — aborting incremental save'); return true; }());
          return;
        }
      }
    }

    // H8: Wait for any in-flight save before scheduling new one
    if (_saveInFlight != null && !_saveInFlight!.isCompleted) {
      await _saveInFlight!.future;
    }

    _saveInFlight = Completer<void>();
    try {
      _incrementalSave.saveNewSegments(segments);
    } finally {
      if (!_saveInFlight!.isCompleted) {
        _saveInFlight!.complete();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Recovery Save (C4: atomic writes)
  // ---------------------------------------------------------------------------

  /// Schedules a recovery save with debouncing.
  /// Saves every 5 seconds or after 5 new segments, whichever comes first.
  /// Saves immediately on the first segment to prevent data loss on early crash.
  void scheduleRecoverySave(
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

    // Save immediately if 15+ unsaved segments (reduced from 5 to avoid hot-path I/O)
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
        draftConversationId: _incrementalSave.draftId,
        synchronous: synchronous,
      );

      _captureLog.log('recovery', 'recovery_data_saved', severity: 'debug', details: {
        'segments_count': segmentsCopy.length,
        'draft_id': _incrementalSave.draftId,
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
  /// Segments are pre-serialized to Maps on main thread (fast: only ref copies),
  /// then the full JSON structure + jsonEncode runs in an isolate via compute().
  Future<void> _atomicSaveRecovery({
    required String sessionId,
    required DateTime startedAt,
    required List<TranscriptSegment> segments,
    String? draftConversationId,
    bool synchronous = false,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final targetFile = File('${directory.path}/transcript_recovery.json');
    final tempFile = File('${directory.path}/transcript_recovery.json.tmp');

    // Pre-serialize segments to primitive Maps (fast: ~0.5ms per segment).
    // The expensive jsonEncode of the full tree runs in the isolate.
    final segmentMaps = segments.map((s) => s.toJson()).toList();
    final now = DateTime.now().toIso8601String();
    final startedAtStr = startedAt.toIso8601String();

    if (synchronous) {
      final json = <String, dynamic>{
        'session_id': sessionId,
        'started_at': startedAtStr,
        'last_updated_at': now,
        'segments': segmentMaps,
        if (draftConversationId != null)
          'draft_conversation_id': draftConversationId,
      };
      final jsonString = jsonEncode(json);
      await tempFile.writeAsString(jsonString);
    } else {
      final payload = <String, dynamic>{
        'session_id': sessionId,
        'started_at': startedAtStr,
        'last_updated_at': now,
        'segments': segmentMaps,
        if (draftConversationId != null)
          'draft_conversation_id': draftConversationId,
      };
      final jsonString = await compute(_encodeJsonMap, payload);
      await tempFile.writeAsString(jsonString);
    }

    await tempFile.rename(targetFile.path);
  }

  /// Isolate entry point: encodes a Map<String, dynamic> to JSON string.
  /// Runs entirely off the main thread.
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
  // Finalize Conversation (C2: Mutex, H9: split into sub-methods)
  // ---------------------------------------------------------------------------

  /// Finalizes a recording session, persisting the conversation.
  ///
  /// Uses a [Mutex] (C2) to prevent concurrent finalize calls.
  /// Returns true if the conversation was successfully saved.
  ///
  /// [onSuccess] is called after a successful save to refresh the UI.
  /// [totalSegmentCount] overrides the internal counter if provided (for testing).
  Future<bool> finalizeConversation({
    required List<TranscriptSegment> segments,
    required String? userId,
    required DateTime? startedAt,
    required bool isSpeechProfileMode,
    required Function() onSuccess,
    int? totalSegmentCount,
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
        effectiveTotalCount: totalSegmentCount ?? _totalSegmentCount,
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
    required int effectiveTotalCount,
  }) async {
    // Capture mutable state upfront
    final localSegments = List<TranscriptSegment>.from(segments);
    final localDraftId = _incrementalSave.draftId;

    final transcript = localSegments.map((s) => s.text).join('\n').trim();
    _captureLog.log('save', 'finalize_started', details: {
      'segments_count': localSegments.length,
      'has_draft': localDraftId != null,
      'transcript_length': transcript.length,
    });

    debugPrint('[PersistenceManager] START: ${localSegments.length} segments, '
        'draftId=$localDraftId, transcript=${transcript.length} chars');

    // Cancel recovery timer (don't clear data yet — only after successful save)
    _recoveryTimer?.cancel();

    // Resolve userId if null
    var effectiveUserId = userId;
    if (effectiveUserId == null) {
      debugPrint('[PersistenceManager] userId null, attempting fetch...');
      effectiveUserId = await SupabaseAuthService.instance.fetchMaityUserId();
    }
    debugPrint('[PersistenceManager] userId=$effectiveUserId');

    // H2: Retry with exponential backoff (2s, 4s, 8s)
    const maxRetries = 3;
    int retryCount = 0;
    bool success = false;

    while (retryCount < maxRetries && !success) {
      try {
        // --- Incremental path ---
        if (localDraftId != null && effectiveUserId != null) {
          success = await _finalizeIncremental(
            localSegments,
            localDraftId,
            effectiveUserId,
            transcript,
          );
        }

        // --- Monolithic fallback ---
        if (!success) {
          // H7: Skip monolithic if segments were trimmed (they are already in Supabase)
          if (effectiveTotalCount > localSegments.length) {
            debugPrint('[PersistenceManager] WARNING: segments were trimmed '
                '(have ${localSegments.length}/$effectiveTotalCount). '
                'Segments are already in Supabase — skipping monolithic fallback.');
            _captureLog.log('save', 'monolithic_skipped_trimmed', severity: 'warning', details: {
              'available': localSegments.length,
              'total': effectiveTotalCount,
            });
            // If incremental failed AND we can't do monolithic, don't retry further
            break;
          }

          success = await _fallbackMonolithic(
            localSegments,
            startedAt ?? DateTime.now(),
            localDraftId,
          );
        }

        if (success) {
          await clearRecoveryState();
          onSuccess();
        }
      } catch (e, stackTrace) {
        retryCount++;
        _captureLog.log('save', 'finalize_retry_error', severity: 'error', details: {
          'attempt': retryCount,
          'max_retries': maxRetries,
          'error': e.toString(),
        });
        debugPrint('[PersistenceManager] ERROR attempt $retryCount/$maxRetries: $e');
        debugPrint('[PersistenceManager] Stack trace: $stackTrace');

        if (retryCount < maxRetries) {
          // H2: Exponential backoff 2s, 4s, 8s
          final delay = Duration(seconds: 2 * (1 << (retryCount - 1)));
          debugPrint('[PersistenceManager] Retrying in ${delay.inSeconds}s...');
          await Future.delayed(delay);
        } else {
          _captureLog.log('save', 'finalize_all_retries_exhausted', severity: 'error', details: {
            'segments_count': localSegments.length,
          });
          debugPrint('[PersistenceManager] All retries exhausted. Recovery data preserved.');
        }
      }
    }

    return success;
  }

  // ---------------------------------------------------------------------------
  // H9: Split _finalizeLocalConversation into sub-methods
  // ---------------------------------------------------------------------------

  /// Flushes any pending segments to Supabase before finalize.
  Future<void> _flushPendingSegments(List<TranscriptSegment> segments, String draftId) async {
    debugPrint('[PersistenceManager] Flushing pending segments...');

    // H8: Concurrent flush guard
    if (_saveInFlight != null && !_saveInFlight!.isCompleted) {
      debugPrint('[PersistenceManager] Waiting for in-flight save to complete...');
      await _saveInFlight!.future;
    }

    _saveInFlight = Completer<void>();
    try {
      await _incrementalSave.flushPendingSegments(segments);
      debugPrint('[PersistenceManager] Flush complete. '
          'Saved: ${_incrementalSave.savedSegmentCount}/${segments.length}');
    } finally {
      if (!_saveInFlight!.isCompleted) {
        _saveInFlight!.complete();
      }
    }
  }

  /// Processes segments locally with OpenAI (for transcripts <= 6000 chars).
  Future<Map<String, dynamic>?> _processLocally(List<TranscriptSegment> segments) async {
    final transcript = segments.map((s) => s.text).join('\n').trim();

    if (transcript.length > 6000) {
      debugPrint('[PersistenceManager] Long transcript (${transcript.length} chars), backend will process');
      return null;
    }

    debugPrint('[PersistenceManager] Processing locally (${transcript.length} chars)...');
    final structured = await ConversationProcessor.processLocally(segments);
    debugPrint('[PersistenceManager] Local result: ${structured != null ? 'title="${structured.title}"' : 'null'}');

    if (structured == null) return null;

    return {
      'title': structured.title,
      'overview': structured.overview,
      'emoji': structured.emoji,
      'category': structured.category,
      'discarded': structured.discarded,
      'action_items': structured.actionItems.map((a) => a.toJson()).toList(),
      'events': structured.events.map((e) => e.toJson()).toList(),
    };
  }

  /// Finalizes via incremental path (draft + backend).
  Future<bool> _finalizeIncremental(
    List<TranscriptSegment> segments,
    String draftId,
    String userId,
    String transcript,
  ) async {
    debugPrint('[PersistenceManager] Incremental path: draft=$draftId');

    await _flushPendingSegments(segments, draftId);

    final structuredData = await _processLocally(segments);

    debugPrint('[PersistenceManager] Calling finalize (structured=${structuredData != null})...');
    final finalized = await _incrementalSave.finalize(
      userId: userId,
      finishedAt: DateTime.now(),
      structured: structuredData,
      draftId: draftId,
    );

    if (finalized) {
      _captureLog.log('save', 'finalize_incremental_success', details: {
        'draft_id': draftId,
      });
      debugPrint('[PersistenceManager] SUCCESS via incremental path');
      return true;
    }

    _captureLog.log('save', 'finalize_incremental_failed', severity: 'warning', details: {
      'draft_id': draftId,
      'fallback': 'monolithic',
    });
    debugPrint('[PersistenceManager] FAILED incremental path, falling back to monolithic');
    return false;
  }

  /// Monolithic fallback: processes + saves the full conversation locally.
  Future<bool> _fallbackMonolithic(
    List<TranscriptSegment> segments,
    DateTime startedAt,
    String? draftId,
  ) async {
    debugPrint('[PersistenceManager] Monolithic path: processing locally...');
    final structured = await ConversationProcessor.processLocally(segments);
    debugPrint('[PersistenceManager] Monolithic result: ${structured != null ? 'title="${structured.title}"' : 'null'}');

    final conversation = await LocalConversationsService.saveConversation(
      segments: List.from(segments),
      startedAt: startedAt,
      structured: structured,
      title: structured?.title ?? 'Conversacion',
      emoji: structured?.emoji ?? '\u{1F3A4}',
      category: structured?.category ?? 'personal',
    );

    debugPrint('[PersistenceManager] Monolithic save OK: id=${conversation.id}, title="${structured?.title}"');
    _captureLog.log('save', 'finalize_monolithic_success', details: {
      'conversation_id': conversation.id,
    });

    // Mark the orphan draft as abandoned so it doesn't linger as 'recording'
    if (draftId != null) {
      debugPrint('[PersistenceManager] Marking orphan draft $draftId as abandoned...');
      try {
        await OmiSupabaseService.markDraftAbandoned(conversationId: draftId);
        debugPrint('[PersistenceManager] Draft marked as abandoned');
      } catch (e) {
        debugPrint('[PersistenceManager] Failed to mark draft as abandoned (non-blocking): $e');
      }
    }

    return true;
  }

  // ---------------------------------------------------------------------------
  // Recover Interrupted Session
  // ---------------------------------------------------------------------------

  /// Recovers an interrupted session from recovery data.
  /// Returns true if recovery was successful.
  ///
  /// [onConversationSaved] is called with the saved conversation on monolithic path.
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
      'draft_id': draftConversationId,
    });
    debugPrint('[PersistenceManager] Recovering ${recoverySegments.length} segments '
        '(draft: $draftConversationId)');

    try {
      final userId = SupabaseAuthService.instance.maityUserId;
      if (userId == null) {
        debugPrint('[PersistenceManager] No user ID, cannot recover');
        return false;
      }

      // If we have a draft conversation, finalize it via backend
      if (draftConversationId != null) {
        debugPrint('[PersistenceManager] Finalizing draft $draftConversationId from recovery');

        final structuredData = await _processLocally(recoverySegments);

        final finalized = await OmiSupabaseService.finalizeConversation(
          conversationId: draftConversationId,
          userId: userId,
          finishedAt: DateTime.now(),
          structured: structuredData,
        );

        if (finalized) {
          debugPrint('[PersistenceManager] Draft finalized from recovery');
          onConversationsRefreshed();
          await TranscriptRecoveryService.clearRecoveryData();
          return true;
        }

        debugPrint('[PersistenceManager] Draft finalize failed, falling back to monolithic save');
      }

      // Fallback: monolithic save
      final structured = await ConversationProcessor.processLocally(recoverySegments);

      final conversation = await LocalConversationsService.saveConversation(
        segments: List.from(recoverySegments),
        startedAt: startedAt,
        structured: structured,
        title: structured?.title ?? 'Recovered Conversation',
        emoji: structured?.emoji ?? '\u{1F504}',
        category: structured?.category ?? 'personal',
      );

      debugPrint('[PersistenceManager] Recovered conversation saved: ${conversation.id}');
      _captureLog.log('recovery', 'recovery_succeeded', details: {
        'conversation_id': conversation.id,
        'segments_count': recoverySegments.length,
      });

      onConversationSaved(conversation);
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
  /// Returns true if the session is worth recovering.
  bool isWorthRecovering(RecoverySession session) {
    if (session.segments.isEmpty) return false;

    // A draft always warrants recovery (segments are in Supabase already)
    if (session.draftConversationId != null) return true;

    // M1: Stricter threshold than RecoverySession.isWorthRecovering (5 words)
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
  // Segment Trimming
  // ---------------------------------------------------------------------------

  /// Trims segments that have been confirmed saved to Supabase,
  /// keeping at most [_maxSegmentsInMemory] segments in memory.
  /// Returns the number of segments trimmed.
  int trimSavedSegments(List<TranscriptSegment> segments) {
    final savedCount = _incrementalSave.savedSegmentCount;
    if (savedCount <= 0 || segments.length <= _maxSegmentsInMemory) return 0;

    final trimCount = (savedCount - _maxSegmentsInMemory).clamp(0, savedCount);
    if (trimCount <= 0) return 0;

    assert(() {
      debugPrint('[PersistenceManager] Trimming $trimCount saved segments '
          '(total: ${segments.length}, saved: $savedCount, '
          'keeping: ${segments.length - trimCount})');
      return true;
    }());

    // sublist+clear+addAll preserves list identity without O(n) shifts
    final kept = segments.sublist(trimCount);
    segments.clear();
    segments.addAll(kept);
    _incrementalSave.adjustAfterTrim(trimCount);

    _captureLog.log('memory', 'segments_trimmed', severity: 'debug', details: {
      'trimmed': trimCount,
      'remaining': segments.length,
      'total_produced': _totalSegmentCount,
    });

    return trimCount;
  }

  // ---------------------------------------------------------------------------
  // Orphan Drafts Cleanup (C6)
  // ---------------------------------------------------------------------------

  /// Cleans up orphan draft conversations from previous interrupted sessions.
  /// C6: Backend should include `last_segment_at IS NULL AND created_at < 1h`.
  /// Non-blocking: runs in background without affecting app startup.
  Future<void> cleanupOrphanDrafts(String? userId) async {
    if (userId == null) return;
    try {
      await OmiSupabaseService.cleanupOrphanDrafts(userId: userId);
    } catch (e) {
      debugPrint('[PersistenceManager] Orphan cleanup failed (non-blocking): $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Force Finalize (wraps forceProcessingCurrentConversation logic)
  // ---------------------------------------------------------------------------

  /// Forces finalization and then resets state.
  /// C3: Acquires mutex so reset waits for any in-progress finalize.
  ///
  /// Returns true if finalization succeeded.
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
    // C3: Reset only after finalize completes (mutex already released)
    reset();
    return result;
  }

  // ---------------------------------------------------------------------------
  // Reset / Dispose
  // ---------------------------------------------------------------------------

  /// Resets all persistence state for a new recording session.
  /// C3: If a finalize is in progress, this waits for it to complete first.
  void reset() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _unsavedSegmentCount = 0;
    _totalSegmentCount = 0;
    _incrementalSave.reset();
    _saveInFlight = null;
    _draftCreationInFlight = null;
  }

  /// Async reset that waits for any in-progress finalize to complete (C3).
  /// Use this when reset might race with a concurrent finalize.
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
    _incrementalSave.reset();
    _saveInFlight = null;
    _draftCreationInFlight = null;
  }
}
