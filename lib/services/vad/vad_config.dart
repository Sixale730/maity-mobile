/// Configuration for Voice Activity Detection (VAD).
/// VAD filters out silence to reduce transcription costs by only sending audio when speech is detected.
class VadConfig {
  /// Whether VAD is enabled. Default: false
  final bool enabled;

  /// Threshold for speech detection (0.0 - 1.0). Higher = more strict.
  /// Default: 0.5 (balanced between false positives and missed speech)
  final double speechThreshold;

  /// Pre-roll buffer in milliseconds. Audio before speech detection is buffered
  /// and sent when speech starts, to capture word beginnings.
  /// Default: 300ms
  final int preRollMs;

  /// Hang-over time in milliseconds. After speech ends, continue sending
  /// for this duration to capture word endings.
  /// Default: 500ms
  final int hangOverMs;

  /// Minimum speech duration in milliseconds. Ignore speech segments shorter
  /// than this to filter out noise/clicks.
  /// Default: 100ms
  final int minSpeechMs;

  const VadConfig({
    this.enabled = false,
    this.speechThreshold = 0.5,
    this.preRollMs = 300,
    this.hangOverMs = 500,
    this.minSpeechMs = 100,
  });

  /// Default configuration (VAD disabled)
  static const VadConfig defaultConfig = VadConfig();

  /// Copy with modified values
  VadConfig copyWith({
    bool? enabled,
    double? speechThreshold,
    int? preRollMs,
    int? hangOverMs,
    int? minSpeechMs,
  }) {
    return VadConfig(
      enabled: enabled ?? this.enabled,
      speechThreshold: speechThreshold ?? this.speechThreshold,
      preRollMs: preRollMs ?? this.preRollMs,
      hangOverMs: hangOverMs ?? this.hangOverMs,
      minSpeechMs: minSpeechMs ?? this.minSpeechMs,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'speechThreshold': speechThreshold,
      'preRollMs': preRollMs,
      'hangOverMs': hangOverMs,
      'minSpeechMs': minSpeechMs,
    };
  }

  /// Deserialize from JSON
  factory VadConfig.fromJson(Map<String, dynamic> json) {
    return VadConfig(
      enabled: json['enabled'] as bool? ?? false,
      speechThreshold: (json['speechThreshold'] as num?)?.toDouble() ?? 0.5,
      preRollMs: json['preRollMs'] as int? ?? 300,
      hangOverMs: json['hangOverMs'] as int? ?? 500,
      minSpeechMs: json['minSpeechMs'] as int? ?? 100,
    );
  }

  /// Unique identifier for this configuration (used to detect config changes)
  String get configId {
    return '$enabled-$speechThreshold-$preRollMs-$hangOverMs-$minSpeechMs';
  }

  @override
  String toString() {
    return 'VadConfig(enabled: $enabled, threshold: $speechThreshold, preRoll: ${preRollMs}ms, hangOver: ${hangOverMs}ms, minSpeech: ${minSpeechMs}ms)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VadConfig &&
        other.enabled == enabled &&
        other.speechThreshold == speechThreshold &&
        other.preRollMs == preRollMs &&
        other.hangOverMs == hangOverMs &&
        other.minSpeechMs == minSpeechMs;
  }

  @override
  int get hashCode {
    return Object.hash(enabled, speechThreshold, preRollMs, hangOverMs, minSpeechMs);
  }
}
