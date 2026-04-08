import 'dart:math';
import 'dart:typed_data';

/// Window size for pitch analysis: 25 ms at 16 kHz.
const int kPitchWindowSamples = 400;

/// Hop size for pitch analysis: 10 ms at 16 kHz.
const int kPitchHopSamples = 160;

/// Minimum fundamental frequency (Hz).
const double kMinF0Hz = 80.0;

/// Maximum fundamental frequency (Hz).
const double kMaxF0Hz = 400.0;

/// Normalized autocorrelation threshold for voiced detection.
const double kAutocorrelationThreshold = 0.5;

/// Minimum valid frames required for F0 statistics.
const int kMinValidFramesForStats = 3;

/// Estimate the fundamental frequency (F0) of a speech segment.
///
/// Uses autocorrelation with a 25 ms window and 10 ms hop.
/// Searches for the F0 in the [80 Hz, 400 Hz] range.
/// Returns the median F0 across valid frames, or null if no voiced frames.
double? estimateF0(Float32List samples, {int sampleRate = 16000}) {
  if (samples.length < kPitchWindowSamples) return null;

  final minLag = (sampleRate / kMaxF0Hz).floor(); // ~40 @ 16kHz
  final maxLag = (sampleRate / kMinF0Hz).ceil(); // ~200 @ 16kHz

  final validF0s = <double>[];

  for (var start = 0;
      start + kPitchWindowSamples <= samples.length;
      start += kPitchHopSamples) {
    final f0 = _analyzeFrame(samples, start, minLag, maxLag, sampleRate);
    if (f0 != null) validF0s.add(f0);
  }

  if (validF0s.isEmpty) return null;

  // Return median
  validF0s.sort();
  return validF0s[validF0s.length ~/ 2];
}

/// Estimate F0 statistics (mean and standard deviation).
///
/// Returns null if fewer than [kMinValidFramesForStats] valid frames found.
({double mean, double std})? estimateF0Stats(Float32List samples,
    {int sampleRate = 16000}) {
  if (samples.length < kPitchWindowSamples) return null;

  final minLag = (sampleRate / kMaxF0Hz).floor();
  final maxLag = (sampleRate / kMinF0Hz).ceil();

  final validF0s = <double>[];

  for (var start = 0;
      start + kPitchWindowSamples <= samples.length;
      start += kPitchHopSamples) {
    final f0 = _analyzeFrame(samples, start, minLag, maxLag, sampleRate);
    if (f0 != null) validF0s.add(f0);
  }

  if (validF0s.length < kMinValidFramesForStats) return null;

  var sum = 0.0;
  for (final f in validF0s) {
    sum += f;
  }
  final mean = sum / validF0s.length;

  var sumSqDiff = 0.0;
  for (final f in validF0s) {
    final diff = f - mean;
    sumSqDiff += diff * diff;
  }
  final std = sqrt(sumSqDiff / validF0s.length);

  return (mean: mean, std: std);
}

/// Gaussian similarity score between a segment F0 and a profile F0 mean.
///
/// Returns a value in [0, 1]. Higher when the F0 values are close.
/// [tolerance] controls the width of the Gaussian (default 30 Hz).
double pitchScore(double segmentF0, double profileF0Mean,
    {double tolerance = 30.0}) {
  final diff = (segmentF0 - profileF0Mean).abs();
  return exp(-(diff * diff) / (2.0 * tolerance * tolerance));
}

/// Analyze a single frame for F0 using autocorrelation.
double? _analyzeFrame(
    Float32List samples, int start, int minLag, int maxLag, int sampleRate) {
  final end = start + kPitchWindowSamples;
  if (end > samples.length) return null;
  if (maxLag >= kPitchWindowSamples) return null;

  // Autocorrelation at lag 0 (energy)
  var r0 = 0.0;
  for (var i = start; i < end; i++) {
    r0 += samples[i] * samples[i];
  }
  if (r0 <= 0.0) return null;

  // Search for peak autocorrelation in the F0 range
  var bestLag = -1;
  var bestCorr = 0.0;

  for (var lag = minLag; lag <= maxLag && lag < kPitchWindowSamples; lag++) {
    var corr = 0.0;
    for (var i = start; i < end - lag; i++) {
      corr += samples[i] * samples[i + lag];
    }
    // Normalize by energy
    final normalized = corr / r0;
    if (normalized > bestCorr) {
      bestCorr = normalized;
      bestLag = lag;
    }
  }

  if (bestLag <= 0 || bestCorr < kAutocorrelationThreshold) return null;

  return sampleRate / bestLag.toDouble();
}
