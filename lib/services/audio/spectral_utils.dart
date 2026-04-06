import 'dart:math';
import 'dart:typed_data';

/// FFT window size: 512 samples (32 ms at 16 kHz).
const int kFftSize = 512;

/// Spectral analysis hop: 10 ms at 16 kHz.
const int kSpectralHopSamples = 160;

/// Default range for spectral centroid scoring (Hz).
const double kDefaultSpectralRange = 2000.0;

/// Small epsilon to avoid log(0).
const double _kEpsilon = 1e-10;

/// Spectral features extracted from an audio segment.
class SpectralFeatures {
  /// Spectral centroid: center of mass in Hz.
  final double centroid;

  /// Spectral slope: linear regression of log-magnitudes over frequency.
  final double slope;

  const SpectralFeatures({required this.centroid, required this.slope});

  @override
  String toString() =>
      'SpectralFeatures(centroid: ${centroid.toStringAsFixed(1)} Hz, '
      'slope: ${slope.toStringAsFixed(6)})';
}

/// Extract mean spectral centroid and slope from an audio segment.
///
/// Uses Cooley-Tukey radix-2 FFT with a 512-point Hanning window and
/// 10 ms hop. Returns null if the segment is shorter than [kFftSize] samples.
SpectralFeatures? extractSpectralFeatures(Float32List samples,
    {int sampleRate = 16000}) {
  if (samples.length < kFftSize) return null;

  final window = _hanningWindow(kFftSize);
  const halfBins = kFftSize ~/ 2 + 1; // 257 bins
  final freqPerBin = sampleRate / kFftSize;

  var totalCentroid = 0.0;
  var totalSlope = 0.0;
  var frameCount = 0;

  for (var start = 0;
      start + kFftSize <= samples.length;
      start += kSpectralHopSamples) {
    // Apply Hanning window and prepare FFT buffers
    final real = Float64List(kFftSize);
    final imag = Float64List(kFftSize);
    for (var i = 0; i < kFftSize; i++) {
      real[i] = samples[start + i] * window[i];
    }

    _fft(real, imag);

    // Compute magnitude spectrum (first half + DC)
    final magnitudes = Float64List(halfBins);
    for (var i = 0; i < halfBins; i++) {
      magnitudes[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]);
    }

    // Spectral centroid: Σ(f_i × |X_i|) / Σ|X_i|
    var weightedSum = 0.0;
    var magSum = 0.0;
    for (var i = 0; i < halfBins; i++) {
      final freq = i * freqPerBin;
      weightedSum += freq * magnitudes[i];
      magSum += magnitudes[i];
    }
    if (magSum > _kEpsilon) {
      totalCentroid += weightedSum / magSum;
    }

    // Spectral slope: linear regression of log-magnitude over frequency
    // Skip bin 0 (DC) to avoid bias
    totalSlope += _computeSlope(magnitudes, freqPerBin);

    frameCount++;
  }

  if (frameCount == 0) return null;

  return SpectralFeatures(
    centroid: totalCentroid / frameCount,
    slope: totalSlope / frameCount,
  );
}

/// Linear spectral score: similarity between two centroid values.
///
/// Returns (1 - |diff| / range) clamped to [0, 1].
double spectralScore(double segmentCentroid, double profileCentroid,
    {double range = kDefaultSpectralRange}) {
  final diff = (segmentCentroid - profileCentroid).abs();
  return (1.0 - diff / range).clamp(0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// In-place Cooley-Tukey radix-2 FFT.
///
/// [real] and [imag] must have the same power-of-2 length.
void _fft(Float64List real, Float64List imag) {
  final n = real.length;
  if (n <= 1) return;

  // Bit-reversal permutation
  var j = 0;
  for (var i = 0; i < n; i++) {
    if (i < j) {
      // Swap real
      final tmpR = real[i];
      real[i] = real[j];
      real[j] = tmpR;
      // Swap imag
      final tmpI = imag[i];
      imag[i] = imag[j];
      imag[j] = tmpI;
    }
    var m = n >> 1;
    while (m >= 1 && j >= m) {
      j -= m;
      m >>= 1;
    }
    j += m;
  }

  // Butterfly stages
  for (var size = 2; size <= n; size <<= 1) {
    final halfSize = size >> 1;
    final angle = -2.0 * pi / size;

    for (var i = 0; i < n; i += size) {
      for (var k = 0; k < halfSize; k++) {
        final theta = angle * k;
        final twiddleR = cos(theta);
        final twiddleI = sin(theta);

        final evenIdx = i + k;
        final oddIdx = i + k + halfSize;

        final oddR = real[oddIdx] * twiddleR - imag[oddIdx] * twiddleI;
        final oddI = real[oddIdx] * twiddleI + imag[oddIdx] * twiddleR;

        real[oddIdx] = real[evenIdx] - oddR;
        imag[oddIdx] = imag[evenIdx] - oddI;
        real[evenIdx] = real[evenIdx] + oddR;
        imag[evenIdx] = imag[evenIdx] + oddI;
      }
    }
  }
}

/// Compute spectral slope via linear regression of log-magnitude on frequency.
///
/// Skips bin 0 (DC). Uses cov(freq, logMag) / var(freq).
double _computeSlope(Float64List magnitudes, double freqPerBin) {
  final n = magnitudes.length;
  if (n < 2) return 0.0;

  // Compute means (skip bin 0)
  final count = n - 1;
  var sumFreq = 0.0;
  var sumLogMag = 0.0;

  for (var i = 1; i < n; i++) {
    sumFreq += i * freqPerBin;
    sumLogMag += log(magnitudes[i] + _kEpsilon);
  }

  final meanFreq = sumFreq / count;
  final meanLogMag = sumLogMag / count;

  // Covariance and variance
  var cov = 0.0;
  var varFreq = 0.0;

  for (var i = 1; i < n; i++) {
    final freq = i * freqPerBin;
    final logMag = log(magnitudes[i] + _kEpsilon);
    final dFreq = freq - meanFreq;
    cov += dFreq * (logMag - meanLogMag);
    varFreq += dFreq * dFreq;
  }

  if (varFreq <= 0.0) return 0.0;
  return cov / varFreq;
}

/// Cached Hanning window of given size.
Float64List? _cachedWindow;
int _cachedWindowSize = 0;

Float64List _hanningWindow(int size) {
  if (_cachedWindow != null && _cachedWindowSize == size) {
    return _cachedWindow!;
  }
  final w = Float64List(size);
  for (var i = 0; i < size; i++) {
    w[i] = 0.5 * (1.0 - cos(2.0 * pi * i / (size - 1)));
  }
  _cachedWindow = w;
  _cachedWindowSize = size;
  return w;
}
