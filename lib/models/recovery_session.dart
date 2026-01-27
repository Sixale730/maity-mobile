import 'package:omi/backend/schema/transcript_segment.dart';

/// Represents an interrupted recording session that can be recovered
class RecoverySession {
  final String sessionId;
  final DateTime startedAt;
  final DateTime lastUpdatedAt;
  final List<TranscriptSegment> segments;

  RecoverySession({
    required this.sessionId,
    required this.startedAt,
    required this.lastUpdatedAt,
    required this.segments,
  });

  /// Total word count across all segments
  int get wordCount {
    return segments.fold<int>(0, (sum, segment) {
      return sum + segment.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    });
  }

  /// Estimated duration based on segment timestamps
  Duration get estimatedDuration {
    if (segments.isEmpty) return Duration.zero;

    final lastEnd = segments.map((s) => s.end).reduce((a, b) => a > b ? a : b);
    return Duration(seconds: lastEnd.toInt());
  }

  /// Number of segments
  int get segmentCount => segments.length;

  /// Check if session has enough content to be worth recovering
  bool get isWorthRecovering {
    return segments.isNotEmpty && wordCount >= 5;
  }

  /// Create from JSON
  factory RecoverySession.fromJson(Map<String, dynamic> json) {
    return RecoverySession(
      sessionId: json['session_id'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      lastUpdatedAt: DateTime.parse(json['last_updated_at'] as String),
      segments: (json['segments'] as List<dynamic>)
          .map((s) => TranscriptSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      'started_at': startedAt.toIso8601String(),
      'last_updated_at': lastUpdatedAt.toIso8601String(),
      'segments': segments.map((s) => s.toJson()).toList(),
    };
  }

  @override
  String toString() {
    return 'RecoverySession(id: $sessionId, segments: $segmentCount, words: $wordCount, duration: ${estimatedDuration.inSeconds}s)';
  }
}
