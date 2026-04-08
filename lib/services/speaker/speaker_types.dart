// ---------------------------------------------------------------------------
// Speaker scoring thresholds
// ---------------------------------------------------------------------------

/// Minimum fused score to classify as user.
const double kUserThreshold = 0.52;

/// High-confidence user threshold (above this, skip heuristic correction).
const double kHighConfThreshold = 0.62;

/// Below this score, the segment is in the "gray zone" for neighbor consensus.
const double kGrayZoneThreshold = 0.40;

/// Segments shorter than this use the short-segment weight profile.
const double kShortSegmentSec = 1.5;

/// Segments at or above this use the long-segment weight profile.
const double kLongSegmentSec = 5.0;

/// Maximum gap (seconds) for temporal boost to apply.
const double kTemporalGapSec = 1.0;

/// Minimum previous-segment confidence for temporal boost.
const double kTemporalPrevConfMin = 0.60;

// ---------------------------------------------------------------------------
// Signal weights
// ---------------------------------------------------------------------------

/// Weight distribution across the 5 scoring signals.
class SignalWeights {
  final double embedding;
  final double energy;
  final double pitch;
  final double duration;
  final double spectral;

  const SignalWeights({
    required this.embedding,
    required this.energy,
    required this.pitch,
    required this.duration,
    required this.spectral,
  });

  /// Default weights for normal-length segments with embedding available.
  static const defaultWeights = SignalWeights(
    embedding: 0.65,
    energy: 0.15,
    pitch: 0.05,
    duration: 0.05,
    spectral: 0.10,
  );

  /// Weights when no speaker embedding is available.
  static const noEmbeddingWeights = SignalWeights(
    embedding: 0.00,
    energy: 0.45,
    pitch: 0.25,
    duration: 0.05,
    spectral: 0.25,
  );

  /// Weights for short segments (< 1.5 s) — embeddings less reliable.
  static const shortSegmentWeights = SignalWeights(
    embedding: 0.35,
    energy: 0.35,
    pitch: 0.12,
    duration: 0.05,
    spectral: 0.13,
  );

  /// Weights for long segments (>= 5.0 s) — embeddings very reliable.
  static const longSegmentWeights = SignalWeights(
    embedding: 0.75,
    energy: 0.10,
    pitch: 0.05,
    duration: 0.02,
    spectral: 0.08,
  );

  Map<String, dynamic> toJson() => {
        'embedding': embedding,
        'energy': energy,
        'pitch': pitch,
        'duration': duration,
        'spectral': spectral,
      };
}

// ---------------------------------------------------------------------------
// Acoustic profile (computed during enrollment)
// ---------------------------------------------------------------------------

/// Acoustic fingerprint of the enrolled user's voice.
///
/// Computed from enrollment audio and stored alongside the speaker embedding.
class AcousticProfile {
  /// Mean fundamental frequency (Hz).
  final double f0Mean;

  /// Standard deviation of F0 (Hz).
  final double f0Std;

  /// Mean RMS energy (dB).
  final double energyDbMean;

  /// Mean spectral centroid (Hz).
  final double spectralCentroid;

  /// Mean spectral slope.
  final double spectralSlope;

  const AcousticProfile({
    required this.f0Mean,
    required this.f0Std,
    required this.energyDbMean,
    required this.spectralCentroid,
    required this.spectralSlope,
  });

  factory AcousticProfile.fromJson(Map<String, dynamic> json) {
    return AcousticProfile(
      f0Mean: (json['f0_mean'] as num).toDouble(),
      f0Std: (json['f0_std'] as num).toDouble(),
      energyDbMean: (json['energy_db_mean'] as num).toDouble(),
      spectralCentroid: (json['spectral_centroid'] as num).toDouble(),
      spectralSlope: (json['spectral_slope'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'f0_mean': f0Mean,
        'f0_std': f0Std,
        'energy_db_mean': energyDbMean,
        'spectral_centroid': spectralCentroid,
        'spectral_slope': spectralSlope,
      };
}

// ---------------------------------------------------------------------------
// Per-segment acoustic features (computed in real time)
// ---------------------------------------------------------------------------

/// Acoustic features extracted from a single transcript segment's audio.
class SegmentAcousticFeatures {
  /// RMS energy in dB [-60, 0].
  final double energyDb;

  /// Estimated fundamental frequency (Hz), or null if unvoiced.
  final double? f0;

  /// Spectral centroid (Hz), or null if too short.
  final double? spectralCentroid;

  /// Duration of the segment in seconds.
  final double durationSec;

  const SegmentAcousticFeatures({
    required this.energyDb,
    this.f0,
    this.spectralCentroid,
    required this.durationSec,
  });
}

// ---------------------------------------------------------------------------
// Fused score result (output of multi-signal scorer)
// ---------------------------------------------------------------------------

/// Complete diagnostics from the multi-signal fusion scorer.
class FusedScoreResult {
  /// Final fused confidence score [0, 1].
  final double score;

  /// Individual signal scores.
  final double embeddingScore;
  final double energyScore;
  final double pitchScore;
  final double spectralScore;
  final double durationScore;

  /// Weights that were applied.
  final SignalWeights weights;

  /// Weighted sum before temporal boost.
  final double fusedBeforeBoost;

  /// Temporal continuity boost applied.
  final double temporalBoost;

  const FusedScoreResult({
    required this.score,
    required this.embeddingScore,
    required this.energyScore,
    required this.pitchScore,
    required this.spectralScore,
    required this.durationScore,
    required this.weights,
    required this.fusedBeforeBoost,
    required this.temporalBoost,
  });

  Map<String, dynamic> toJson() => {
        'score': score,
        'embedding_score': embeddingScore,
        'energy_score': energyScore,
        'pitch_score': pitchScore,
        'spectral_score': spectralScore,
        'duration_score': durationScore,
        'weights': weights.toJson(),
        'fused_before_boost': fusedBeforeBoost,
        'temporal_boost': temporalBoost,
      };
}

// ---------------------------------------------------------------------------
// Scored segment (input for heuristic corrections)
// ---------------------------------------------------------------------------

/// A transcript segment with its fused confidence score attached.
///
/// Used as input for [applyHeuristicCorrections].
class ScoredSegment {
  final int index;
  final String text;
  final int speakerId;
  final double confidence;
  final double startTime;
  final double endTime;

  const ScoredSegment({
    required this.index,
    required this.text,
    required this.speakerId,
    required this.confidence,
    required this.startTime,
    required this.endTime,
  });

  double get durationSec => endTime - startTime;
}

// ---------------------------------------------------------------------------
// Correction record (output of heuristic corrections)
// ---------------------------------------------------------------------------

/// Record of a speaker correction applied by heuristic rules.
class CorrectionRecord {
  /// Index of the corrected segment in the segments list.
  final int segmentIndex;

  /// Original speaker ID before correction.
  final int originalSpeaker;

  /// New speaker ID after correction.
  final int correctedSpeaker;

  /// Source of the correction (e.g., 'heuristic', 'reanalysis', 'user').
  final String correctionSource;

  /// Name of the specific rule that triggered the correction.
  final String ruleName;

  /// Confidence of the correction [0, 1].
  final double correctionConfidence;

  const CorrectionRecord({
    required this.segmentIndex,
    required this.originalSpeaker,
    required this.correctedSpeaker,
    required this.correctionSource,
    required this.ruleName,
    required this.correctionConfidence,
  });

  Map<String, dynamic> toJson() => {
        'segment_index': segmentIndex,
        'original_speaker': originalSpeaker,
        'corrected_speaker': correctedSpeaker,
        'correction_source': correctionSource,
        'rule_name': ruleName,
        'correction_confidence': correctionConfidence,
      };
}
