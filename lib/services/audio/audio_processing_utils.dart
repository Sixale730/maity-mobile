import 'dart:math';
import 'dart:typed_data';

/// Default sample rate for all audio processing (16 kHz mono).
const int kDefaultSampleRate = 16000;

/// Target peak level for normalization: -3 dBFS ≈ 0.707 linear.
const double kTargetPeakLinear = 0.707;

/// Floor value for RMS dB computation.
const double kMinRmsDb = -60.0;

/// First-order IIR high-pass filter at 80 Hz.
///
/// Removes body rumble and AC hum (50/60 Hz) from speech audio.
/// Uses forward-difference approximation: α = RC / (RC + dt).
Float32List highPassFilter80Hz(Float32List samples,
    {int sampleRate = kDefaultSampleRate}) {
  if (samples.isEmpty) return Float32List(0);

  const rc = 1.0 / (2.0 * pi * 80.0);
  final dt = 1.0 / sampleRate;
  final alpha = rc / (rc + dt);

  final result = Float32List(samples.length);
  result[0] = samples[0];

  for (var i = 1; i < samples.length; i++) {
    result[i] = alpha * (result[i - 1] + samples[i] - samples[i - 1]);
  }
  return result;
}

/// DC removal followed by peak normalization to -3 dBFS.
///
/// Step 1: subtract mean (DC offset removal).
/// Step 2: scale so that the absolute peak equals [kTargetPeakLinear].
Float32List normalizeAudio(Float32List samples) {
  if (samples.isEmpty) return Float32List(0);

  // DC removal
  var sum = 0.0;
  for (var i = 0; i < samples.length; i++) {
    sum += samples[i];
  }
  final mean = sum / samples.length;

  final result = Float32List(samples.length);
  var maxAbs = 0.0;
  for (var i = 0; i < samples.length; i++) {
    result[i] = samples[i] - mean;
    final abs = result[i].abs();
    if (abs > maxAbs) maxAbs = abs;
  }

  // Peak normalize
  if (maxAbs > 0.0) {
    final scale = kTargetPeakLinear / maxAbs;
    for (var i = 0; i < result.length; i++) {
      result[i] *= scale;
    }
  }
  return result;
}

/// Cosine similarity between two vectors.
///
/// Returns a value in [-1, 1]. Returns 0.0 if either vector has zero norm.
double cosineSimilarity(Float32List a, Float32List b) {
  assert(a.length == b.length, 'Vectors must have equal length');
  if (a.isEmpty) return 0.0;

  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }

  final denom = sqrt(normA) * sqrt(normB);
  if (denom == 0.0) return 0.0;
  return (dot / denom).clamp(-1.0, 1.0);
}

/// P75 (75th percentile) similarity for multi-sample fusion.
///
/// When [individualEmbeddings] has ≥3 entries, computes cosine similarity of
/// [embedding] against each individual sample, sorts, and returns the 75th
/// percentile. Otherwise falls back to direct [cosineSimilarity] against
/// [profile].
double computeP75Similarity(
  Float32List embedding,
  Float32List profile,
  List<Float32List>? individualEmbeddings,
) {
  if (individualEmbeddings == null || individualEmbeddings.length < 3) {
    return cosineSimilarity(embedding, profile);
  }

  final similarities = <double>[];
  for (final sample in individualEmbeddings) {
    similarities.add(cosineSimilarity(embedding, sample));
  }
  similarities.sort();

  // 75th percentile with linear interpolation
  final p75Exact = (similarities.length - 1) * 0.75;
  final lower = p75Exact.floor();
  final upper = (lower + 1).clamp(0, similarities.length - 1);
  final frac = p75Exact - lower;
  return similarities[lower] * (1.0 - frac) + similarities[upper] * frac;
}

/// L2 (Euclidean) normalization to unit sphere.
///
/// Returns a zero vector if the input has zero norm.
Float32List l2Normalize(Float32List v) {
  if (v.isEmpty) return Float32List(0);

  var sumSq = 0.0;
  for (var i = 0; i < v.length; i++) {
    sumSq += v[i] * v[i];
  }
  final norm = sqrt(sumSq);
  if (norm == 0.0) return Float32List(v.length);

  final result = Float32List(v.length);
  for (var i = 0; i < v.length; i++) {
    result[i] = v[i] / norm;
  }
  return result;
}

/// Convert PCM16 little-endian bytes to Float32 samples normalized to [-1, 1].
///
/// This is the canonical implementation — deduplicates copies in
/// local_stt_worker.dart and speaker_embedding_service.dart.
Float32List pcm16ToFloat32(Uint8List pcm16Bytes) {
  final numSamples = pcm16Bytes.length ~/ 2;
  final result = Float32List(numSamples);
  final byteData = ByteData.sublistView(pcm16Bytes);
  for (var i = 0; i < numSamples; i++) {
    final int16 = byteData.getInt16(i * 2, Endian.little);
    result[i] = int16 / 32768.0;
  }
  return result;
}

/// Convert Float32 samples [-1, 1] to PCM16 little-endian bytes.
Uint8List float32ToPcm16(Float32List samples) {
  final byteData = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    final int16 = (clamped * 32767.0).round();
    byteData.setInt16(i * 2, int16, Endian.little);
  }
  return byteData.buffer.asUint8List();
}

/// RMS energy in decibels, clamped to [[kMinRmsDb], 0].
///
/// Returns [kMinRmsDb] (-60 dB) for silence or empty input.
double computeRmsDb(Float32List samples) {
  if (samples.isEmpty) return kMinRmsDb;

  var sumSq = 0.0;
  for (var i = 0; i < samples.length; i++) {
    sumSq += samples[i] * samples[i];
  }
  final rms = sqrt(sumSq / samples.length);
  if (rms <= 0.0) return kMinRmsDb;

  final db = 20.0 * log(rms) / ln10;
  return db.clamp(kMinRmsDb, 0.0);
}
