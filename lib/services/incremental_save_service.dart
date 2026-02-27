import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/omi_supabase_service.dart';

/// Service for incrementally saving transcript segments to Supabase
/// during an active recording session.
///
/// Flow: Segment arrives → RAM + Recovery File (every 5s) + Supabase (every 30s)
///
/// This ensures that even if the app crashes, segments saved to Supabase
/// can be recovered and finalized into a complete conversation.
class IncrementalSaveService {
  CaptureLogService get _captureLog => CaptureLogService.instance;

  /// The draft conversation ID in Supabase (null until first segment)
  String? _draftId;
  String? get draftId => _draftId;

  /// Number of segments already confirmed saved to Supabase
  int _savedSegmentCount = 0;
  int get savedSegmentCount => _savedSegmentCount;

  /// Debounce timer for batch saves
  Timer? _saveTimer;

  /// Whether a save operation is currently in progress
  bool _isSaving = false;

  /// Whether the service has been initialized for this session
  bool _isActive = false;

  /// Most recent segment list reference (avoids stale closure in debounce timer)
  List<TranscriptSegment>? _lastKnownSegments;

  // Debounce configuration
  static const Duration _saveDebounce = Duration(seconds: 30);
  static const int _segmentThreshold = 20;
  static const int _maxBatchSize = 50;

  /// Ensure a draft conversation exists in Supabase.
  /// Creates one on first call, returns existing ID on subsequent calls.
  Future<String?> ensureDraftCreated({
    required String userId,
    required DateTime startedAt,
    String source = 'omi',
  }) async {
    if (_draftId != null) return _draftId;

    try {
      debugPrint('[IncrementalSave] Creating draft conversation...');
      final result = await OmiSupabaseService.createDraftConversation(
        userId: userId,
        startedAt: startedAt,
        source: source,
      );

      if (result != null) {
        _draftId = result;
        _isActive = true;
        _captureLog.log('save', 'incremental_draft_created', details: {
          'draft_id': _draftId,
        });
        debugPrint('[IncrementalSave] Draft created: $_draftId');
      }

      return _draftId;
    } catch (e) {
      _captureLog.log('save', 'incremental_draft_failed', severity: 'error', details: {
        'error': e.toString(),
      });
      debugPrint('[IncrementalSave] Failed to create draft: $e');
      return null;
    }
  }

  /// Schedule saving new segments to Supabase.
  /// Uses debouncing: saves every 30s or when 20+ new segments accumulate.
  void saveNewSegments(List<TranscriptSegment> allSegments) {
    if (!_isActive || _draftId == null) return;

    // Always update the reference to avoid stale closures in the debounce timer
    _lastKnownSegments = allSegments;

    final newSegmentCount = allSegments.length - _savedSegmentCount;
    if (newSegmentCount <= 0) return;

    // Save immediately if we have enough new segments
    if (newSegmentCount >= _segmentThreshold) {
      _performSave();
      return;
    }

    // Otherwise, debounce (timer uses _lastKnownSegments, not a captured reference)
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => _performSave());
  }

  /// Perform the actual save operation using _lastKnownSegments
  Future<void> _performSave() async {
    final allSegments = _lastKnownSegments;
    if (_isSaving || _draftId == null || !_isActive || allSegments == null) return;

    final newCount = allSegments.length - _savedSegmentCount;
    if (newCount <= 0) return;

    _isSaving = true;
    _saveTimer?.cancel();

    try {
      // Get the new segments to save (from savedSegmentCount onwards)
      final startIndex = _savedSegmentCount;
      final endIndex = (startIndex + _maxBatchSize).clamp(0, allSegments.length);
      final batch = allSegments.sublist(startIndex, endIndex);

      if (batch.isEmpty) {
        _isSaving = false;
        return;
      }

      _captureLog.log('save', 'incremental_batch_started', severity: 'debug', details: {
        'batch_size': batch.length,
        'offset': startIndex,
        'total': allSegments.length,
      });
      debugPrint('[IncrementalSave] Saving ${batch.length} segments (offset: $startIndex)');

      // Get userId from the segments' context - we need it for the API call
      final success = await OmiSupabaseService.appendSegments(
        conversationId: _draftId!,
        segments: batch,
        segmentOffset: startIndex,
      );

      if (success) {
        _savedSegmentCount = endIndex;
        _captureLog.log('save', 'incremental_batch_success', details: {
          'saved_count': _savedSegmentCount,
          'total': allSegments.length,
        });
        debugPrint('[IncrementalSave] Saved. Total confirmed: $_savedSegmentCount');

        // If there are more segments to save, schedule another batch
        // Validate draftId and isActive to avoid orphaned timer chains
        if (endIndex < allSegments.length && _draftId != null && _isActive) {
          _saveTimer = Timer(const Duration(seconds: 2), () => _performSave());
        }
      } else {
        _captureLog.log('save', 'incremental_batch_failed', severity: 'error', details: {
          'offset': startIndex,
          'batch_size': batch.length,
        });
        debugPrint('[IncrementalSave] Save failed, will retry on next trigger');
      }
    } catch (e) {
      _captureLog.log('save', 'incremental_batch_failed', severity: 'error', details: {
        'error': e.toString(),
      });
      debugPrint('[IncrementalSave] Error saving segments: $e');
    } finally {
      _isSaving = false;
    }
  }

  /// Force save all pending segments immediately
  Future<void> flushPendingSegments(List<TranscriptSegment> allSegments) async {
    _saveTimer?.cancel();
    _lastKnownSegments = allSegments;
    if (_draftId == null || allSegments.length <= _savedSegmentCount) return;

    // Save all remaining segments in batches with retry protection
    int maxRetries = 5;
    int retries = 0;
    int lastSaved = _savedSegmentCount;

    while (_savedSegmentCount < allSegments.length && retries < maxRetries) {
      await _performSave();
      if (_savedSegmentCount == lastSaved) {
        // No progress was made, increment retry counter
        retries++;
        await Future.delayed(Duration(seconds: retries));
      } else {
        // Progress was made, reset retry counter
        retries = 0;
        lastSaved = _savedSegmentCount;
      }
    }

    if (retries >= maxRetries) {
      _captureLog.log('save', 'incremental_flush_gave_up', severity: 'error', details: {
        'saved': _savedSegmentCount,
        'total': allSegments.length,
        'max_retries': maxRetries,
      });
      debugPrint('[IncrementalSave] Flush gave up after $maxRetries retries. Saved: $_savedSegmentCount/${allSegments.length}');
    }
  }

  /// Finalize the draft conversation in Supabase.
  /// Backend rebuilds transcript from segments, generates embeddings, etc.
  /// Finalize the draft conversation in Supabase.
  /// Backend rebuilds transcript from segments, generates embeddings, etc.
  /// [draftId] allows caller to pass a captured draftId (protects against concurrent reset).
  Future<bool> finalize({
    required String userId,
    required DateTime finishedAt,
    Map<String, dynamic>? structured,
    bool generateEmbeddings = true,
    String? draftId,
  }) async {
    final effectiveDraftId = draftId ?? _draftId;
    if (effectiveDraftId == null) {
      debugPrint('[IncrementalSave] No draft to finalize (draftId=null)');
      return false;
    }

    try {
      debugPrint('[IncrementalSave] Finalizing draft=$effectiveDraftId, '
          'userId=$userId, '
          'hasStructured=${structured != null}, '
          'structuredTitle=${structured?['title']}, '
          'savedSegments=$_savedSegmentCount');
      final success = await OmiSupabaseService.finalizeConversation(
        conversationId: effectiveDraftId,
        userId: userId,
        finishedAt: finishedAt,
        structured: structured,
        generateEmbeddings: generateEmbeddings,
      );

      if (success) {
        _captureLog.log('save', 'incremental_finalize_success', details: {
          'draft_id': effectiveDraftId,
        });
        debugPrint('[IncrementalSave] Finalized successfully');
      } else {
        _captureLog.log('save', 'incremental_finalize_failed', severity: 'error', details: {
          'draft_id': effectiveDraftId,
        });
        debugPrint('[IncrementalSave] Finalize FAILED (returned false)');
      }

      return success;
    } catch (e, stackTrace) {
      _captureLog.log('save', 'incremental_finalize_error', severity: 'error', details: {
        'draft_id': effectiveDraftId,
        'error': e.toString(),
      });
      debugPrint('[IncrementalSave] Error finalizing: $e');
      debugPrint('[IncrementalSave] Stack trace: $stackTrace');
      return false;
    }
  }

  /// Adjusts savedSegmentCount after the provider trims old segments from memory.
  /// When prefix segments are removed, both the list and the offset shrink together.
  void adjustAfterTrim(int trimmedCount) {
    _savedSegmentCount = (_savedSegmentCount - trimmedCount).clamp(0, _savedSegmentCount);
    debugPrint('[IncrementalSave] Adjusted after trim: -$trimmedCount, new savedSegmentCount=$_savedSegmentCount');
  }

  /// Reset state for next recording session
  void reset() {
    _captureLog.log('save', 'incremental_reset', severity: 'debug');
    _saveTimer?.cancel();
    _saveTimer = null;
    _draftId = null;
    _savedSegmentCount = 0;
    _isSaving = false;
    _isActive = false;
    _lastKnownSegments = null;
  }

  /// Set draft ID from recovery (when recovering a session that had a draft)
  void setDraftId(String draftId) {
    _draftId = draftId;
    _isActive = true;
  }
}
