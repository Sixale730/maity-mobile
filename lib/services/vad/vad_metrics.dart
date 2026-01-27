/// Metrics for tracking VAD performance and cost savings.
class VadMetrics {
  /// Total audio frames processed by VAD
  int totalAudioFrames;

  /// Frames sent to transcription service
  int sentAudioFrames;

  /// Frames filtered (not sent)
  int filteredAudioFrames;

  /// Number of speech segments detected
  int speechSegments;

  /// Timestamp when tracking started
  DateTime? startTime;

  VadMetrics({
    this.totalAudioFrames = 0,
    this.sentAudioFrames = 0,
    this.filteredAudioFrames = 0,
    this.speechSegments = 0,
    this.startTime,
  });

  /// Reset all metrics
  void reset() {
    totalAudioFrames = 0;
    sentAudioFrames = 0;
    filteredAudioFrames = 0;
    speechSegments = 0;
    startTime = DateTime.now();
  }

  /// Record a frame being processed
  void recordFrame({required bool sent}) {
    totalAudioFrames++;
    if (sent) {
      sentAudioFrames++;
    } else {
      filteredAudioFrames++;
    }
  }

  /// Record a new speech segment starting
  void recordSpeechSegmentStart() {
    speechSegments++;
  }

  /// Percentage of audio filtered (not sent)
  /// Returns 0.0 if no frames processed
  double get filterRatio {
    if (totalAudioFrames == 0) return 0.0;
    return filteredAudioFrames / totalAudioFrames;
  }

  /// Percentage of audio sent
  double get sendRatio {
    if (totalAudioFrames == 0) return 0.0;
    return sentAudioFrames / totalAudioFrames;
  }

  /// Estimated savings percentage (0-100)
  double get savingsPercent => filterRatio * 100;

  /// Total duration processed (assuming 16kHz, 512 samples = 32ms per frame)
  double get totalSeconds {
    return totalAudioFrames * 0.032; // 32ms per frame
  }

  /// Duration sent to transcription
  double get sentSeconds {
    return sentAudioFrames * 0.032;
  }

  /// Duration filtered (saved)
  double get filteredSeconds {
    return filteredAudioFrames * 0.032;
  }

  /// Session duration
  Duration get sessionDuration {
    if (startTime == null) return Duration.zero;
    return DateTime.now().difference(startTime!);
  }

  /// Create a copy of current metrics
  VadMetrics copy() {
    return VadMetrics(
      totalAudioFrames: totalAudioFrames,
      sentAudioFrames: sentAudioFrames,
      filteredAudioFrames: filteredAudioFrames,
      speechSegments: speechSegments,
      startTime: startTime,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'totalAudioFrames': totalAudioFrames,
      'sentAudioFrames': sentAudioFrames,
      'filteredAudioFrames': filteredAudioFrames,
      'speechSegments': speechSegments,
      'filterRatio': filterRatio,
      'savingsPercent': savingsPercent,
      'totalSeconds': totalSeconds,
      'sentSeconds': sentSeconds,
      'filteredSeconds': filteredSeconds,
    };
  }

  @override
  String toString() {
    return 'VadMetrics('
        'total: $totalAudioFrames frames (${totalSeconds.toStringAsFixed(1)}s), '
        'sent: $sentAudioFrames (${sentSeconds.toStringAsFixed(1)}s), '
        'filtered: $filteredAudioFrames (${filteredSeconds.toStringAsFixed(1)}s), '
        'savings: ${savingsPercent.toStringAsFixed(1)}%, '
        'segments: $speechSegments'
        ')';
  }
}
