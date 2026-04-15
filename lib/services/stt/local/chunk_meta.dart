/// State machine for audio chunk lifecycle.
///
/// ```
/// pending → processing → completed → deleted
/// ```
enum ChunkState {
  /// Written to disk, waiting for worker to process.
  pending,

  /// Currently being decoded by the worker isolate.
  processing,

  /// Successfully decoded; segments emitted to pipeline.
  completed,

  /// PCM file deleted after conversation finalization.
  deleted,
}

/// Metadata for a single 5-second PCM16 audio chunk on disk.
///
/// Each chunk represents ~160 KB of raw PCM16 audio (16 kHz, mono, 5 seconds).
/// Chunks are written by [AudioChunkWriter] and processed by the worker isolate
/// via [ChunkQueueManager].
class ChunkMeta {
  final String sessionId;
  final int sequence;
  final String filePath;
  final int byteCount;
  final DateTime createdAt;
  ChunkState state;

  ChunkMeta({
    required this.sessionId,
    required this.sequence,
    required this.filePath,
    required this.byteCount,
    required this.createdAt,
    this.state = ChunkState.pending,
  });

  /// Offset in seconds from session start for timestamp correction.
  /// Each chunk covers [offsetSeconds, offsetSeconds + duration).
  double get offsetSeconds => sequence * 5.0;

  /// Duration in seconds based on byte count (PCM16, 16 kHz, mono = 32000 bytes/sec).
  double get durationSeconds => byteCount / 32000.0;

  factory ChunkMeta.fromJson(Map<String, dynamic> json) {
    return ChunkMeta(
      sessionId: json['session_id'] as String,
      sequence: json['sequence'] as int,
      filePath: json['file_path'] as String,
      byteCount: json['byte_count'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
      state: ChunkState.values.byName(json['state'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'sequence': sequence,
        'file_path': filePath,
        'byte_count': byteCount,
        'created_at': createdAt.toIso8601String(),
        'state': state.name,
      };
}
