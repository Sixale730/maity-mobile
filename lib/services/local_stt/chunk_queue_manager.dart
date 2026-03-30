import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omi/services/local_stt/chunk_meta.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the lifecycle of audio chunks for local STT recording sessions.
///
/// This is the **coordinator** in the log-structured processing pipeline.
/// It tracks chunk state (pending → processing → completed → deleted),
/// persists the index to JSON for crash recovery, and drives the worker
/// isolate by feeding it chunks in FIFO order.
///
/// Usage:
/// ```dart
/// await ChunkQueueManager.instance.initialize();
/// await ChunkQueueManager.instance.startSession(sessionId);
/// // AudioChunkWriter calls enqueueChunk() on each flush
/// // ChunkQueueManager calls processNextChunk() to drive the worker
/// ```
class ChunkQueueManager {
  static final ChunkQueueManager _instance = ChunkQueueManager._();
  static ChunkQueueManager get instance => _instance;

  /// Per-session chunk index: sessionId → ordered list of ChunkMeta.
  final Map<String, List<ChunkMeta>> _chunkIndex = {};

  /// Tracks which sessions have been finalized (ready for cleanup).
  final Set<String> _finalizedSessions = {};

  /// Whether the worker is currently processing a chunk.
  bool _workerBusy = false;

  /// Callback to send a chunk to the worker for processing.
  /// Set by TranscriptionPipeline when wiring up the local STT socket.
  void Function(ChunkMeta chunk)? onProcessChunk;

  /// Callback invoked when a chunk is completed (for pipeline notification).
  void Function(String chunkId)? onChunkCompleted;

  String? _cachedSupportDir;
  bool _initialized = false;

  static const String _indexFileName = 'chunk_index.json';

  ChunkQueueManager._();

  /// Initialize: load persisted index, recover pending chunks.
  Future<void> initialize() async {
    if (_initialized) return;
    _cachedSupportDir ??=
        (await getApplicationSupportDirectory()).path;
    await _loadIndex();
    await recoverPendingChunks();
    _initialized = true;
    debugPrint(
        '[ChunkQueueManager] Initialized. Sessions: ${_chunkIndex.length}');
  }

  /// Start a new session. Creates the chunk directory.
  Future<String> startSession(String sessionId) async {
    _cachedSupportDir ??=
        (await getApplicationSupportDirectory()).path;
    final dir = getSessionDir(sessionId);
    await Directory(dir).create(recursive: true);
    _chunkIndex[sessionId] = [];
    _finalizedSessions.remove(sessionId);
    _workerBusy = false;
    await _saveIndex();
    debugPrint('[ChunkQueueManager] Session started: $sessionId → $dir');
    return dir;
  }

  /// Get the base directory for a session's chunks.
  String getSessionDir(String sessionId) {
    return '$_cachedSupportDir/audio_chunks/$sessionId';
  }

  /// Enqueue a new chunk (called by AudioChunkWriter.onChunkWritten).
  Future<void> enqueueChunk(ChunkMeta meta) async {
    _chunkIndex.putIfAbsent(meta.sessionId, () => []);
    _chunkIndex[meta.sessionId]!.add(meta);
    await _saveIndex();
    debugPrint(
        '[ChunkQueueManager] Enqueued chunk ${meta.sequence} for ${meta.sessionId} '
        '(${meta.byteCount} bytes)');

    // If worker is idle, kick off processing.
    if (!_workerBusy) {
      processNextChunk(meta.sessionId);
    }
  }

  /// Get and process the next pending chunk for a session.
  void processNextChunk([String? sessionId]) {
    final chunk = _nextPendingChunk(sessionId);
    if (chunk == null) {
      _workerBusy = false;
      debugPrint('[ChunkQueueManager] No pending chunks to process');
      return;
    }

    _workerBusy = true;
    chunk.state = ChunkState.processing;
    _saveIndex(); // Fire-and-forget persistence

    debugPrint(
        '[ChunkQueueManager] Processing chunk ${chunk.sequence} '
        '(${chunk.byteCount} bytes, offset ${chunk.offsetSeconds}s)');
    onProcessChunk?.call(chunk);
  }

  /// Mark a chunk as completed. Called when the worker finishes decoding.
  Future<void> markCompleted(String sessionId, int sequence) async {
    final chunks = _chunkIndex[sessionId];
    if (chunks == null) return;

    final chunk = chunks.where((c) => c.sequence == sequence).firstOrNull;
    if (chunk == null) return;

    chunk.state = ChunkState.completed;
    await _saveIndex();

    final chunkId = '${sessionId}_$sequence';
    debugPrint('[ChunkQueueManager] Chunk $sequence completed for $sessionId');
    onChunkCompleted?.call(chunkId);

    // Process next pending chunk.
    processNextChunk(sessionId);
  }

  /// Check if all chunks for a session are completed.
  bool allChunksCompleted(String sessionId) {
    final chunks = _chunkIndex[sessionId];
    if (chunks == null || chunks.isEmpty) return true;
    return chunks.every(
        (c) => c.state == ChunkState.completed || c.state == ChunkState.deleted);
  }

  /// Check if there are pending chunks.
  bool hasPendingChunks([String? sessionId]) {
    if (sessionId != null) {
      return _chunkIndex[sessionId]?.any(
              (c) => c.state == ChunkState.pending || c.state == ChunkState.processing) ??
          false;
    }
    return _chunkIndex.values
        .any((chunks) => chunks.any(
            (c) => c.state == ChunkState.pending || c.state == ChunkState.processing));
  }

  /// Mark session as finalized (conversation uploaded).
  /// Chunks can now be safely deleted.
  Future<void> markSessionFinalized(String sessionId) async {
    _finalizedSessions.add(sessionId);
    debugPrint('[ChunkQueueManager] Session finalized: $sessionId');

    // If all chunks are completed, clean up immediately.
    if (allChunksCompleted(sessionId)) {
      await cleanupSession(sessionId);
    }
  }

  /// Delete all PCM files and index entries for a finalized session.
  Future<void> cleanupSession(String sessionId) async {
    final chunks = _chunkIndex[sessionId];
    if (chunks == null) return;

    int deletedCount = 0;
    for (final chunk in chunks) {
      try {
        final file = File(chunk.filePath);
        if (await file.exists()) {
          await file.delete();
          deletedCount++;
        }
      } catch (e) {
        debugPrint(
            '[ChunkQueueManager] Error deleting chunk ${chunk.sequence}: $e');
      }
    }

    _chunkIndex.remove(sessionId);
    _finalizedSessions.remove(sessionId);
    await _saveIndex();

    // Try to remove session directory.
    try {
      final dir = Directory(getSessionDir(sessionId));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}

    debugPrint(
        '[ChunkQueueManager] Cleaned up session $sessionId ($deletedCount files)');
  }

  /// Crash recovery: reset any 'processing' chunks back to 'pending'.
  Future<void> recoverPendingChunks() async {
    int recovered = 0;
    for (final chunks in _chunkIndex.values) {
      for (final chunk in chunks) {
        if (chunk.state == ChunkState.processing) {
          chunk.state = ChunkState.pending;
          recovered++;
        }
      }
    }
    if (recovered > 0) {
      await _saveIndex();
      debugPrint(
          '[ChunkQueueManager] Recovered $recovered chunks from processing → pending');
    }
  }

  /// Get the total number of pending chunks across all sessions.
  int get pendingCount {
    return _chunkIndex.values.fold(
        0,
        (sum, chunks) =>
            sum +
            chunks.where((c) => c.state == ChunkState.pending).length);
  }

  ChunkMeta? _nextPendingChunk([String? sessionId]) {
    if (sessionId != null) {
      return _chunkIndex[sessionId]
          ?.where((c) => c.state == ChunkState.pending)
          .firstOrNull;
    }
    // Across all sessions, pick the oldest pending chunk.
    for (final chunks in _chunkIndex.values) {
      final pending =
          chunks.where((c) => c.state == ChunkState.pending).firstOrNull;
      if (pending != null) return pending;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> _saveIndex() async {
    try {
      final data = {
        'version': 1,
        'sessions': _chunkIndex.map((sessionId, chunks) => MapEntry(
              sessionId,
              {
                'finalized': _finalizedSessions.contains(sessionId),
                'chunks': chunks.map((c) => c.toJson()).toList(),
              },
            )),
      };

      final indexPath = '$_cachedSupportDir/$_indexFileName';
      final tmpPath = '$indexPath.tmp';
      final json = jsonEncode(data);

      await File(tmpPath).writeAsString(json, flush: true);
      if (Platform.isWindows) {
        final target = File(indexPath);
        if (await target.exists()) await target.delete();
      }
      await File(tmpPath).rename(indexPath);
    } catch (e) {
      debugPrint('[ChunkQueueManager] Error saving index: $e');
    }
  }

  Future<void> _loadIndex() async {
    try {
      final indexPath = '$_cachedSupportDir/$_indexFileName';
      final file = File(indexPath);
      if (!await file.exists()) return;

      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final sessions = json['sessions'] as Map<String, dynamic>? ?? {};

      _chunkIndex.clear();
      _finalizedSessions.clear();

      for (final entry in sessions.entries) {
        final sessionId = entry.key;
        final sessionData = entry.value as Map<String, dynamic>;
        final chunksJson = sessionData['chunks'] as List<dynamic>? ?? [];

        _chunkIndex[sessionId] = chunksJson
            .map((c) => ChunkMeta.fromJson(c as Map<String, dynamic>))
            .toList();

        if (sessionData['finalized'] == true) {
          _finalizedSessions.add(sessionId);
        }
      }

      debugPrint(
          '[ChunkQueueManager] Loaded index: ${_chunkIndex.length} sessions');
    } catch (e) {
      debugPrint('[ChunkQueueManager] Error loading index: $e');
      // If corrupted, start fresh.
      _chunkIndex.clear();
    }
  }

  /// Reset state for testing or reinitialization.
  void reset() {
    _chunkIndex.clear();
    _finalizedSessions.clear();
    _workerBusy = false;
    _initialized = false;
    onProcessChunk = null;
    onChunkCompleted = null;
  }
}
