import 'dart:io';
import 'dart:typed_data';

import 'package:omi/backend/schema/transcript_segment.dart';

/// A time gap detected in a transcript where audio exists but no segments.
class TimeGap {
  final double start;
  final double end;
  double get duration => end - start;
  const TimeGap(this.start, this.end);

  @override
  String toString() =>
      'TimeGap(${start.toStringAsFixed(1)}-${end.toStringAsFixed(1)}s, '
      '${duration.toStringAsFixed(1)}s)';
}

/// Utilities for detecting transcript gaps and extracting audio from WAV backup.
///
/// After a recording session, segments may have gaps where the local STT worker
/// failed (OOM, timeout, crash). This service detects those gaps and can extract
/// the corresponding raw audio from the WAV backup file for re-transcription.
class WavGapRecovery {
  /// WAV header size (standard PCM16 mono 16kHz).
  static const int _headerSize = 44;

  /// Bytes per second for PCM16 mono 16kHz audio.
  static const int _bytesPerSecond = 32000;

  /// Detect time gaps in segments larger than [minGapSeconds].
  ///
  /// Scans the sorted segment timeline and returns gaps where no transcription
  /// exists. Useful for identifying failed chunks that could be re-transcribed
  /// from WAV backup.
  ///
  /// [segments] — list of transcript segments from the recording session.
  /// [totalDurationSeconds] — total recording duration (from WAV backup bytes).
  /// [minGapSeconds] — minimum gap duration to report (default 5s).
  /// [maxGaps] — maximum number of gaps to return (default 20).
  static List<TimeGap> detectGaps(
    List<TranscriptSegment> segments,
    double totalDurationSeconds, {
    double minGapSeconds = 5.0,
    int maxGaps = 20,
  }) {
    final gaps = <TimeGap>[];
    if (segments.isEmpty) return gaps;

    final sorted = [...segments]
      ..sort((a, b) => a.start.compareTo(b.start));

    // Check gap at beginning of recording
    if (sorted.first.start > minGapSeconds) {
      gaps.add(TimeGap(0, sorted.first.start));
    }

    // Check gaps between consecutive segments
    for (int i = 0; i < sorted.length - 1 && gaps.length < maxGaps; i++) {
      final gapStart = sorted[i].end;
      final gapEnd = sorted[i + 1].start;
      if (gapEnd - gapStart >= minGapSeconds) {
        gaps.add(TimeGap(gapStart, gapEnd));
      }
    }

    // Check gap at end of recording
    if (gaps.length < maxGaps) {
      final lastEnd = sorted.last.end;
      if (totalDurationSeconds - lastEnd >= minGapSeconds) {
        gaps.add(TimeGap(lastEnd, totalDurationSeconds));
      }
    }

    return gaps;
  }

  /// Extract raw PCM16 audio bytes from a WAV file for a time range.
  ///
  /// Reads the WAV backup file at the byte offset corresponding to
  /// [startSeconds]–[endSeconds] and returns the raw PCM16 data.
  /// Returns null if the file doesn't exist or the range is invalid.
  static Future<Uint8List?> extractAudioFromWav(
    String wavPath,
    double startSeconds,
    double endSeconds,
  ) async {
    final file = File(wavPath);
    if (!file.existsSync()) return null;

    final startByte = _headerSize + (startSeconds * _bytesPerSecond).round();
    final endByte = _headerSize + (endSeconds * _bytesPerSecond).round();
    final length = endByte - startByte;
    if (length <= 0) return null;

    final fileLength = await file.length();
    if (startByte >= fileLength) return null;

    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(startByte);
      final actualLength = (startByte + length > fileLength)
          ? fileLength - startByte
          : length;
      final bytes = await raf.read(actualLength);
      return Uint8List.fromList(bytes);
    } finally {
      await raf.close();
    }
  }
}
