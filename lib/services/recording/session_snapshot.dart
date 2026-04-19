import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/recording/recording_state_machine.dart';

/// Immutable snapshot of a recording session at the moment it stops.
///
/// Captured by [SessionLifecycleManager] during the stopping phase and
/// carried through finalization + upload so every downstream consumer
/// sees a consistent, frozen view of the session — no races with the
/// still-live pipeline.
class SessionSnapshot {
  final String sessionId;
  final List<TranscriptSegment> allSegments;
  final DateTime startedAt;
  final DateTime stoppedAt;
  final String? userId;
  final String? sttProvider;
  final RecordingSource source;
  final String idempotencyKey;

  SessionSnapshot({
    required this.sessionId,
    required this.allSegments,
    required this.startedAt,
    required this.stoppedAt,
    this.userId,
    this.sttProvider,
    required this.source,
    required this.idempotencyKey,
  });

  int get totalWords => allSegments.fold<int>(
      0,
      (sum, s) =>
          sum +
          s.text
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .length);

  int get totalSegments => allSegments.length;

  Duration get duration => stoppedAt.difference(startedAt);

  String get transcriptText =>
      allSegments.map((s) => s.text).join('\n').trim();

  bool get isEmpty => allSegments.isEmpty;
}
