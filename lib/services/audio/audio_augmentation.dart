import 'dart:math';
import 'dart:typed_data';

/// Default pink noise SNR (dB) for enrollment augmentation.
const double kDefaultPinkSnrDb = 15.0;

/// Default babble noise SNR (dB).
const double kDefaultBabbleSnrDb = 10.0;

/// Default low-SNR noise level (dB).
const double kDefaultLowSnrDb = 7.0;

/// Default reverb delay in samples (150 ms at 16 kHz).
const int kDefaultReverbDelay = 2400;

/// Default reverb decay factor.
const double kDefaultReverbDecay = 0.3;

/// Number of self-copies for babble noise.
const int kBabbleVoices = 5;

/// Add pink noise at a given SNR level.
///
/// Uses simplified Voss-McCartney algorithm with 8 octave rows.
/// The signal-to-noise ratio controls how loud the noise is relative
/// to the original signal.
Float32List addPinkNoise(Float32List samples,
    {double snrDb = kDefaultPinkSnrDb, int? seed}) {
  if (samples.isEmpty) return Float32List(0);

  final rng = Random(seed);
  final result = Float32List(samples.length);

  // Generate pink noise via Voss-McCartney (8 rows)
  const rows = 8;
  final rowValues = List<double>.filled(rows, 0.0);
  final pinkNoise = Float64List(samples.length);

  for (var i = 0; i < samples.length; i++) {
    // Determine which rows to update (bit-based schedule)
    for (var r = 0; r < rows; r++) {
      if (i % (1 << r) == 0) {
        rowValues[r] = rng.nextDouble() * 2.0 - 1.0;
      }
    }
    var sum = 0.0;
    for (var r = 0; r < rows; r++) {
      sum += rowValues[r];
    }
    pinkNoise[i] = sum / rows;
  }

  // Compute signal RMS
  final signalRms = _computeRms(samples);
  if (signalRms <= 0.0) return Float32List.fromList(samples);

  // Compute noise RMS and scale to target SNR
  final noiseRms = _computeRmsFloat64(pinkNoise);
  if (noiseRms <= 0.0) return Float32List.fromList(samples);

  final targetNoiseRms = signalRms / pow(10.0, snrDb / 20.0);
  final scale = targetNoiseRms / noiseRms;

  for (var i = 0; i < samples.length; i++) {
    result[i] = samples[i] + (pinkNoise[i] * scale);
  }
  return result;
}

/// Add simple reverb via single-tap delay line.
///
/// [delaySamples] defaults to 2400 (150 ms at 16 kHz).
/// [decay] controls the reflection amplitude (0.0–1.0).
Float32List addSimpleReverb(Float32List samples,
    {int delaySamples = kDefaultReverbDelay,
    double decay = kDefaultReverbDecay}) {
  if (samples.isEmpty) return Float32List(0);

  final result = Float32List(samples.length);
  final delay2 = delaySamples * 2;

  // Use input-based reflections (not feedback) to avoid accumulation/clipping
  for (var i = 0; i < samples.length; i++) {
    result[i] = samples[i];
    if (i >= delaySamples) {
      result[i] += decay * samples[i - delaySamples];
    }
    // Second reflection at 2× delay with squared decay
    if (i >= delay2) {
      result[i] += decay * decay * samples[i - delay2];
    }
  }
  return result;
}

/// Add babble noise by mixing time-shifted copies of the signal itself.
///
/// Creates [kBabbleVoices] copies at random offsets, sums them, then
/// mixes at the target SNR.
Float32List addBabbleNoise(Float32List samples,
    {double snrDb = kDefaultBabbleSnrDb, int? seed}) {
  if (samples.isEmpty) return Float32List(0);

  final rng = Random(seed);
  final n = samples.length;
  final babble = Float64List(n);

  // Sum of shifted copies
  for (var v = 0; v < kBabbleVoices; v++) {
    final offset = rng.nextInt(n);
    for (var i = 0; i < n; i++) {
      babble[i] += samples[(i + offset) % n] / kBabbleVoices;
    }
  }

  // Add white noise component at 50% amplitude
  for (var i = 0; i < n; i++) {
    babble[i] += (rng.nextDouble() * 2.0 - 1.0) * 0.5 / kBabbleVoices;
  }

  // Mix at target SNR
  final signalRms = _computeRms(samples);
  final noiseRms = _computeRmsFloat64(babble);
  if (signalRms <= 0.0 || noiseRms <= 0.0) return Float32List.fromList(samples);

  final targetNoiseRms = signalRms / pow(10.0, snrDb / 20.0);
  final scale = targetNoiseRms / noiseRms;

  final result = Float32List(n);
  for (var i = 0; i < n; i++) {
    result[i] = samples[i] + (babble[i] * scale);
  }
  return result;
}

/// Apply speed perturbation via linear interpolation resampling.
///
/// [speedFactor] < 1.0 slows down (longer output), > 1.0 speeds up (shorter).
/// Typical range: 0.9–1.1.
Float32List addSpeedPerturbation(Float32List samples,
    {double speedFactor = 0.9}) {
  if (samples.isEmpty) return Float32List(0);
  if (speedFactor <= 0.0) return Float32List.fromList(samples);

  final outputLength = (samples.length / speedFactor).round();
  if (outputLength <= 0) return Float32List(0);

  final result = Float32List(outputLength);
  for (var i = 0; i < outputLength; i++) {
    final srcIdx = i * speedFactor;
    final idx0 = srcIdx.floor();
    final idx1 = idx0 + 1;
    final frac = srcIdx - idx0;

    if (idx1 < samples.length) {
      result[i] = samples[idx0] * (1.0 - frac) + samples[idx1] * frac;
    } else if (idx0 < samples.length) {
      result[i] = samples[idx0];
    }
  }
  return result;
}

/// Add white Gaussian noise at a low SNR for stress-testing enrollment.
Float32List addLowSnrNoise(Float32List samples,
    {double snrDb = kDefaultLowSnrDb, int? seed}) {
  if (samples.isEmpty) return Float32List(0);

  final rng = Random(seed);
  final signalRms = _computeRms(samples);
  if (signalRms <= 0.0) return Float32List.fromList(samples);

  final targetNoiseRms = signalRms / pow(10.0, snrDb / 20.0);

  final result = Float32List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    // Approximate Gaussian via sum of 6 uniform (Central Limit Theorem)
    var noise = 0.0;
    for (var j = 0; j < 6; j++) {
      noise += rng.nextDouble();
    }
    noise = (noise - 3.0) / 3.0; // Approx N(0,1)
    result[i] = samples[i] + (noise * targetNoiseRms);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

double _computeRms(Float32List samples) {
  if (samples.isEmpty) return 0.0;
  var sumSq = 0.0;
  for (var i = 0; i < samples.length; i++) {
    sumSq += samples[i] * samples[i];
  }
  return sqrt(sumSq / samples.length);
}

double _computeRmsFloat64(Float64List samples) {
  if (samples.isEmpty) return 0.0;
  var sumSq = 0.0;
  for (var i = 0; i < samples.length; i++) {
    sumSq += samples[i] * samples[i];
  }
  return sqrt(sumSq / samples.length);
}
