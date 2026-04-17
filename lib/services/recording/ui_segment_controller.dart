import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';

/// Manages a bounded window of transcript segments during active recording.
///
/// Replaces the unbounded `List<TranscriptSegment> segments` in
/// [TranscriptionPipeline] with a capped list that archives old segments
/// to disk and supports lazy-load pagination on scroll-up.
///
/// All operations are O(k) where k = [maxActiveSegments] (constant),
/// eliminating the progressive degradation that caused OOM crashes on
/// long recordings.
class UISegmentController {
  static const int maxActiveSegments = 100;
  static const int archiveBatchSize = 50;

  /// Segments currently held in memory for display.
  final List<TranscriptSegment> _activeSegments = [];

  /// Metadata about archived pages (for pagination).
  final List<SegmentArchivePage> _archivePages = [];

  /// Loaded historical pages (lazy-loaded on scroll up).
  final Map<int, List<TranscriptSegment>> _loadedPages = {};

  String? _archiveDir;
  String? _sessionId;
  int _totalSegmentCount = 0;
  int _version = 0;

  /// Current segments available for display.
  List<TranscriptSegment> get activeSegments =>
      List.unmodifiable(_activeSegments);

  /// All displayable segments: loaded archived pages + active segments.
  List<TranscriptSegment> get displaySegments {
    if (_loadedPages.isEmpty) return _activeSegments;

    final result = <TranscriptSegment>[];
    // Add loaded pages in order.
    final sortedPageIndices = _loadedPages.keys.toList()..sort();
    for (final pageIndex in sortedPageIndices) {
      result.addAll(_loadedPages[pageIndex]!);
    }
    result.addAll(_activeSegments);
    return result;
  }

  List<SegmentArchivePage> get archivePages =>
      List.unmodifiable(_archivePages);

  int get totalSegmentCount => _totalSegmentCount;
  int get version => _version;
  bool get hasArchivedPages => _archivePages.isNotEmpty;

  /// Initialize for a new recording session.
  void startSession(String sessionId, String archiveDir) {
    _sessionId = sessionId;
    _archiveDir = archiveDir;
    _activeSegments.clear();
    _archivePages.clear();
    _loadedPages.clear();
    _totalSegmentCount = 0;
    _version = 0;
  }

  /// Add new segments from a decoded chunk.
  ///
  /// Applies merge logic on the bounded active list, then archives
  /// if the cap is exceeded. Returns the number of new segments added.
  int addSegments(List<TranscriptSegment> newSegments) {
    if (newSegments.isEmpty) return 0;

    final insertStartIndex = _activeSegments.length;
    final remainSegments =
        TranscriptSegment.updateSegments(_activeSegments, newSegments);
    _activeSegments.addAll(remainSegments);

    if (remainSegments.isNotEmpty) {
      TranscriptSegment.mergeNewSegmentsAtBoundary(
        _activeSegments,
        insertStartIndex: insertStartIndex,
      );
    }

    _totalSegmentCount += remainSegments.length;
    _version++;

    // Archive if over cap.
    if (_activeSegments.length > maxActiveSegments) {
      _archiveOldest();
    }

    return remainSegments.length;
  }

  /// Load an archived page (for scroll-up pagination).
  Future<List<TranscriptSegment>> loadPage(int pageIndex) async {
    // Return from cache if already loaded.
    if (_loadedPages.containsKey(pageIndex)) {
      return _loadedPages[pageIndex]!;
    }

    if (pageIndex < 0 || pageIndex >= _archivePages.length) {
      return [];
    }

    final page = _archivePages[pageIndex];
    try {
      final file = File(page.filePath);
      if (!await file.exists()) return [];

      final json = jsonDecode(await file.readAsString()) as List<dynamic>;
      final segments =
          json.map((j) => TranscriptSegment.fromJson(j as Map<String, dynamic>)).toList();

      _loadedPages[pageIndex] = segments;
      debugPrint(
          '[UISegmentController] Loaded archive page $pageIndex: ${segments.length} segments');
      return segments;
    } catch (e) {
      debugPrint('[UISegmentController] Error loading page $pageIndex: $e');
      return [];
    }
  }

  /// Unload a page from memory (when scrolled away).
  void unloadPage(int pageIndex) {
    _loadedPages.remove(pageIndex);
  }

  /// Unload all pages.
  void unloadAllPages() {
    _loadedPages.clear();
  }

  /// Archive the oldest batch of segments to disk.
  void _archiveOldest() {
    if (_archiveDir == null || _sessionId == null) return;
    if (_activeSegments.length <= maxActiveSegments) return;

    final archiveCount =
        (_activeSegments.length - maxActiveSegments + archiveBatchSize)
            .clamp(archiveBatchSize, _activeSegments.length - 1);

    final toArchive = _activeSegments.sublist(0, archiveCount);
    _activeSegments.removeRange(0, archiveCount);

    final pageIndex = _archivePages.length;
    final filePath =
        '$_archiveDir/segments_archive_${_sessionId}_$pageIndex.json';

    final page = SegmentArchivePage(
      pageIndex: pageIndex,
      segmentCount: toArchive.length,
      firstTimestamp: toArchive.first.start,
      lastTimestamp: toArchive.last.end,
      filePath: filePath,
    );
    _archivePages.add(page);

    // Write archive async (fire-and-forget, segments are still in active if crash).
    _writeArchivePage(filePath, toArchive);

    debugPrint(
        '[UISegmentController] Archived ${toArchive.length} segments to page $pageIndex. '
        'Active: ${_activeSegments.length}');
  }

  Future<void> _writeArchivePage(
      String filePath, List<TranscriptSegment> segments) async {
    try {
      final json =
          jsonEncode(segments.map((s) => _segmentToJsonWithId(s)).toList());
      final tmpPath = '$filePath.tmp';
      await File(tmpPath).writeAsString(json, flush: true);
      if (Platform.isWindows) {
        final target = File(filePath);
        if (await target.exists()) await target.delete();
      }
      await File(tmpPath).rename(filePath);
    } catch (e) {
      debugPrint('[UISegmentController] Error archiving page: $e');
    }
  }

  /// Serialize segment including `id` (which toJson() omits).
  static Map<String, dynamic> _segmentToJsonWithId(TranscriptSegment s) {
    final json = s.toJson();
    json['id'] = s.id;
    return json;
  }

  /// Collect ALL segments for finalization: active + all archived pages.
  /// Loads unloaded pages temporarily and returns the complete ordered list.
  /// Call BEFORE disposing the orchestrator.
  Future<List<TranscriptSegment>> collectAllSegments() async {
    final result = <TranscriptSegment>[];
    // Load ALL archived pages (including unloaded ones)
    for (int i = 0; i < _archivePages.length; i++) {
      if (_loadedPages.containsKey(i)) {
        result.addAll(_loadedPages[i]!);
      } else {
        final page = await loadPage(i);
        result.addAll(page);
        // Unload to keep memory bounded
        unloadPage(i);
      }
    }
    // Add active segments
    result.addAll(_activeSegments);
    return result;
  }

  /// Clean up all archive files for the current session.
  Future<void> cleanup() async {
    for (final page in _archivePages) {
      try {
        final file = File(page.filePath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    _archivePages.clear();
    _loadedPages.clear();
  }

  void dispose() {
    _activeSegments.clear();
    _archivePages.clear();
    _loadedPages.clear();
  }
}

/// Metadata about an archived page of segments on disk.
class SegmentArchivePage {
  final int pageIndex;
  final int segmentCount;
  final double firstTimestamp;
  final double lastTimestamp;
  final String filePath;

  const SegmentArchivePage({
    required this.pageIndex,
    required this.segmentCount,
    required this.firstTimestamp,
    required this.lastTimestamp,
    required this.filePath,
  });
}
