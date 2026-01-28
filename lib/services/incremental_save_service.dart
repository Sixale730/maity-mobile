import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/omi_supabase_service.dart';

/// Service for incrementally saving transcript segments to Supabase
/// during an active recording session.
///
/// Flow: Segment arrives → RAM + Recovery File (every 5s) + Supabase (every 30s)
///
/// This ensures that even if the app crashes, segments saved to Supabase
/// can be recovered and finalized into a complete conversation.
class IncrementalSaveService {
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
        debugPrint('[IncrementalSave] Draft created: $_draftId');
      }

      return _draftId;
    } catch (e) {
      debugPrint('[IncrementalSave] Failed to create draft: $e');
      return null;
    }
  }

  /// Schedule saving new segments to Supabase.
  /// Uses debouncing: saves every 30s or when 20+ new segments accumulate.
  void saveNewSegments(List<TranscriptSegment> allSegments) {
    if (!_isActive || _draftId == null) return;

    final newSegmentCount = allSegments.length - _savedSegmentCount;
    if (newSegmentCount <= 0) return;

    // Save immediately if we have enough new segments
    if (newSegmentCount >= _segmentThreshold) {
      _performSave(allSegments);
      return;
    }

    // Otherwise, debounce
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => _performSave(allSegments));
  }

  /// Perform the actual save operation
  Future<void> _performSave(List<TranscriptSegment> allSegments) async {
    if (_isSaving || _draftId == null) return;

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

      debugPrint('[IncrementalSave] Saving ${batch.length} segments (offset: $startIndex)');

      // Get userId from the segments' context - we need it for the API call
      final success = await OmiSupabaseService.appendSegments(
        conversationId: _draftId!,
        segments: batch,
        segmentOffset: startIndex,
      );

      if (success) {
        _savedSegmentCount = endIndex;
        debugPrint('[IncrementalSave] Saved. Total confirmed: $_savedSegmentCount');

        // If there are more segments to save, schedule another batch
        if (endIndex < allSegments.length) {
          _saveTimer = Timer(const Duration(seconds: 2), () => _performSave(allSegments));
        }
      } else {
        debugPrint('[IncrementalSave] Save failed, will retry on next trigger');
      }
    } catch (e) {
      debugPrint('[IncrementalSave] Error saving segments: $e');
    } finally {
      _isSaving = false;
    }
  }

  /// Force save all pending segments immediately
  Future<void> flushPendingSegments(List<TranscriptSegment> allSegments) async {
    _saveTimer?.cancel();
    if (_draftId == null || allSegments.length <= _savedSegmentCount) return;

    // Save all remaining segments in batches
    while (_savedSegmentCount < allSegments.length) {
      await _performSave(allSegments);
      if (_isSaving) {
        // Wait for current save to finish
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// Finalize the draft conversation in Supabase.
  /// Backend rebuilds transcript from segments, generates embeddings, etc.
  Future<bool> finalize({
    required String userId,
    required DateTime finishedAt,
    Map<String, dynamic>? structured,
    bool generateEmbeddings = true,
  }) async {
    if (_draftId == null) {
      debugPrint('[IncrementalSave] No draft to finalize');
      return false;
    }

    try {
      debugPrint('[IncrementalSave] Finalizing draft $_draftId...');
      final success = await OmiSupabaseService.finalizeConversation(
        conversationId: _draftId!,
        userId: userId,
        finishedAt: finishedAt,
        structured: structured,
        generateEmbeddings: generateEmbeddings,
      );

      if (success) {
        debugPrint('[IncrementalSave] Finalized successfully');
      } else {
        debugPrint('[IncrementalSave] Finalize failed');
      }

      return success;
    } catch (e) {
      debugPrint('[IncrementalSave] Error finalizing: $e');
      return false;
    }
  }

  /// Reset state for next recording session
  void reset() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _draftId = null;
    _savedSegmentCount = 0;
    _isSaving = false;
    _isActive = false;
  }

  /// Set draft ID from recovery (when recovering a session that had a draft)
  void setDraftId(String draftId) {
    _draftId = draftId;
    _isActive = true;
  }
}
