import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:omi/services/local_stt/chunk_meta.dart';

/// Buffers incoming PCM16 audio bytes in memory and flushes to disk
/// every [_flushInterval] (5 seconds).
///
/// Each flush writes a single `.pcm` file containing raw PCM16 16 kHz mono
/// audio. File size is ~160 KB per 5-second chunk (16000 Hz × 2 bytes × 5 s).
///
/// This is the **producer** in the log-structured processing pipeline.
/// It runs on the main isolate and is O(1) constant — performance never
/// depends on recording duration.
///
/// Writes use an atomic temp-file + rename strategy to prevent corruption
/// if the app is killed mid-write.
class AudioChunkWriter {
  final String sessionId;
  final String _baseDir;
  final void Function(ChunkMeta meta)? onChunkWritten;

  final List<Uint8List> _buffer = [];
  int _bufferBytes = 0;
  int _sequenceNumber = 0;
  /// Number of chunks written to disk so far.
  int get chunksWritten => _sequenceNumber;
  Timer? _flushTimer;
  bool _isFlushing = false;
  bool _disposed = false;

  static const Duration _flushInterval = Duration(seconds: 5);

  /// Minimum buffer size for timer-triggered flushes (0.5s at 16kHz PCM16 mono).
  /// Prevents micro-chunks that are too short for meaningful VAD + decode.
  static const int _minFlushBytes = 16000;

  AudioChunkWriter({
    required this.sessionId,
    required String baseDir,
    this.onChunkWritten,
  }) : _baseDir = baseDir;

  /// Start the periodic flush timer.
  void start() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => _timerFlush());
  }

  /// Add raw PCM16 bytes to the in-memory buffer.
  /// O(1) — just appends to the list, no copying.
  void addBytes(Uint8List pcm16Bytes) {
    if (_disposed) return;
    _buffer.add(pcm16Bytes);
    _bufferBytes += pcm16Bytes.length;
  }

  /// Force flush current buffer to disk.
  ///
  /// Use [synchronous] for app lifecycle pause (where the app may be killed
  /// immediately after). Use async (default) for normal recording stop.
  Future<void> flush({bool synchronous = false}) async {
    if (_buffer.isEmpty) return;
    if (synchronous) {
      _writeChunkToDiskSync();
    } else {
      await _writeChunkToDisk();
    }
  }

  /// Stop the timer and flush remaining buffer.
  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isNotEmpty) {
      await _writeChunkToDisk();
    }
  }

  void _timerFlush() {
    if (_isFlushing || _buffer.isEmpty || _disposed) return;
    if (_bufferBytes < _minFlushBytes) return;
    _writeChunkToDisk();
  }

  Future<void> _writeChunkToDisk() async {
    if (_buffer.isEmpty || _isFlushing) return;
    _isFlushing = true;

    try {
      final frames = List<Uint8List>.from(_buffer);
      final totalBytes = _bufferBytes;
      _buffer.clear();
      _bufferBytes = 0;

      final concatenated = _concatenateFrames(frames, totalBytes);
      final seq = _sequenceNumber++;
      final fileName = 'chunk_${sessionId}_$seq.pcm';
      final filePath = '$_baseDir/$fileName';
      final tmpPath = '$filePath.tmp';

      final file = File(tmpPath);
      await file.writeAsBytes(concatenated, flush: true);

      // Atomic rename (Windows: delete target first)
      final target = File(filePath);
      if (Platform.isWindows && await target.exists()) {
        await target.delete();
      }
      await File(tmpPath).rename(filePath);

      final meta = ChunkMeta(
        sessionId: sessionId,
        sequence: seq,
        filePath: filePath,
        byteCount: concatenated.length,
        createdAt: DateTime.now(),
      );

      debugPrint(
          '[AudioChunkWriter] Wrote chunk $seq: ${concatenated.length} bytes → $fileName');
      onChunkWritten?.call(meta);
    } catch (e, st) {
      debugPrint('[AudioChunkWriter] Error writing chunk: $e\n$st');
    } finally {
      _isFlushing = false;
    }
  }

  /// Synchronous variant for app lifecycle pause where async may not complete.
  void _writeChunkToDiskSync() {
    if (_buffer.isEmpty) return;

    try {
      final frames = List<Uint8List>.from(_buffer);
      final totalBytes = _bufferBytes;
      _buffer.clear();
      _bufferBytes = 0;

      final concatenated = _concatenateFrames(frames, totalBytes);
      final seq = _sequenceNumber++;
      final fileName = 'chunk_${sessionId}_$seq.pcm';
      final filePath = '$_baseDir/$fileName';
      final tmpPath = '$filePath.tmp';

      File(tmpPath).writeAsBytesSync(concatenated, flush: true);

      // Atomic rename
      final target = File(filePath);
      if (Platform.isWindows && target.existsSync()) {
        target.deleteSync();
      }
      File(tmpPath).renameSync(filePath);

      final meta = ChunkMeta(
        sessionId: sessionId,
        sequence: seq,
        filePath: filePath,
        byteCount: concatenated.length,
        createdAt: DateTime.now(),
      );

      debugPrint(
          '[AudioChunkWriter] Wrote chunk $seq (sync): ${concatenated.length} bytes → $fileName');
      onChunkWritten?.call(meta);
    } catch (e, st) {
      debugPrint('[AudioChunkWriter] Sync write error: $e\n$st');
    }
  }

  static Uint8List _concatenateFrames(List<Uint8List> frames, int totalBytes) {
    final result = Uint8List(totalBytes);
    int offset = 0;
    for (final frame in frames) {
      result.setRange(offset, offset + frame.length, frame);
      offset += frame.length;
    }
    return result;
  }
}
