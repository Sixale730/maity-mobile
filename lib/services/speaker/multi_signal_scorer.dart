import 'dart:math';
import 'dart:typed_data';

import 'package:omi/services/audio/audio_processing_utils.dart';
import 'package:omi/services/audio/pitch_utils.dart';
import 'package:omi/services/audio/spectral_utils.dart';
import 'package:omi/services/speaker/speaker_types.dart';

/// Tolerance (dB) for the energy score Gaussian.
const double _kEnergyToleranceDb = 10.0;

/// Sigmoid midpoint for duration score.
const double _kDurationSigmoidMidpoint = 1.5;

/// Sigmoid steepness for duration score.
const double _kDurationSigmoidSteepness = 2.0;

/// Temporal boost base value.
const double _kTemporalBoostBase = 0.05;

/// Compute a fused speaker confidence score from 5 acoustic signals.
///
/// Combines embedding similarity, energy, pitch, spectral, and duration
/// scores with adaptive weights based on segment characteristics.
/// Returns a [FusedScoreResult] with full diagnostics.
FusedScoreResult computeFusedScoreWithDiagnostics({
  required Float32List samples,
  required double embeddingScore,
  required AcousticProfile acousticProfile,
  required double durationSec,
  bool hasEmbedding = true,
  bool prevIsUser = false,
  double prevConfidence = 0.0,
  double prevGapSec = double.infinity,
}) {
  // 1. Select weights based on segment characteristics
  final weights = selectWeights(
    hasEmbedding: hasEmbedding,
    durationSec: durationSec,
  );

  // 2. Compute individual signal scores
  final eScore = _computeEnergyScore(
    computeRmsDb(samples),
    acousticProfile.energyDbMean,
  );

  final f0 = estimateF0(samples);
  final pScore = f0 != null
      ? pitchScore(f0, acousticProfile.f0Mean,
          tolerance: max(acousticProfile.f0Std, 30.0))
      : 0.5; // Neutral if unvoiced

  final spectral = extractSpectralFeatures(samples);
  final sScore = spectral != null
      ? spectralScore(spectral.centroid, acousticProfile.spectralCentroid)
      : 0.5; // Neutral if too short

  final dScore = _computeDurationScore(durationSec);

  // 3. Weighted fusion
  final fusedBeforeBoost = weights.embedding * embeddingScore +
      weights.energy * eScore +
      weights.pitch * pScore +
      weights.spectral * sScore +
      weights.duration * dScore;

  // 4. Temporal continuity boost
  var temporalBoost = 0.0;
  if (prevIsUser &&
      prevConfidence >= kTemporalPrevConfMin &&
      prevGapSec < kTemporalGapSec) {
    final gapDecay = 1.0 - (prevGapSec / kTemporalGapSec);
    final shortBonus = durationSec < 3.0 ? 0.05 : 0.0;
    temporalBoost = (_kTemporalBoostBase +
                (prevConfidence - kTemporalPrevConfMin) * 0.25) *
            gapDecay +
        shortBonus;
    temporalBoost = temporalBoost.clamp(0.0, 0.15);
  }

  // 5. Final score
  final finalScore = (fusedBeforeBoost + temporalBoost).clamp(0.0, 1.0);

  return FusedScoreResult(
    score: finalScore,
    embeddingScore: embeddingScore,
    energyScore: eScore,
    pitchScore: pScore,
    spectralScore: sScore,
    durationScore: dScore,
    weights: weights,
    fusedBeforeBoost: fusedBeforeBoost,
    temporalBoost: temporalBoost,
  );
}

/// Select the appropriate weight profile based on segment characteristics.
SignalWeights selectWeights({
  required bool hasEmbedding,
  required double durationSec,
}) {
  if (!hasEmbedding) return SignalWeights.noEmbeddingWeights;
  if (durationSec < kShortSegmentSec) return SignalWeights.shortSegmentWeights;
  if (durationSec >= kLongSegmentSec) return SignalWeights.longSegmentWeights;
  return SignalWeights.defaultWeights;
}

/// Energy score: Gaussian centered on the user's mean energy level.
double _computeEnergyScore(double segmentDb, double profileDb) {
  final diff = segmentDb - profileDb;
  return exp(-(diff * diff) /
      (2.0 * _kEnergyToleranceDb * _kEnergyToleranceDb));
}

/// Duration score: sigmoid that increases with segment length.
///
/// Longer segments provide more reliable acoustic features.
/// Returns ~0.05 at 0s, ~0.50 at 1.5s, ~0.95 at 3.0s.
double _computeDurationScore(double durationSec) {
  return 1.0 /
      (1.0 +
          exp(-_kDurationSigmoidSteepness *
              (durationSec - _kDurationSigmoidMidpoint)));
}
