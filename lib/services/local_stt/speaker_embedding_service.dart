import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Extracts speaker embeddings from audio using sherpa_onnx's
/// SpeakerEmbeddingExtractor (3D-Speaker CAM++ model, 192-dim).
///
/// Designed for one-shot use during voice enrollment on the main isolate:
/// initialize → extract → save → dispose. The model (~28 MB) loads in ~100ms.
///
/// For worker isolate usage during recording, the extractor is initialized
/// directly in [local_stt_worker.dart] to avoid FFI pointer crossing.
class SpeakerEmbeddingService {
  sherpa.SpeakerEmbeddingExtractor? _extractor;

  bool get isInitialized => _extractor != null;

  int get dim => _extractor?.dim ?? 0;

  /// Initialize the extractor with the speaker model .onnx file.
  void initialize(String modelPath) {
    if (_extractor != null) return;

    final config = sherpa.SpeakerEmbeddingExtractorConfig(
      model: modelPath,
      numThreads: 1,
      debug: false,
      provider: 'cpu',
    );
    _extractor = sherpa.SpeakerEmbeddingExtractor(config: config);
    debugPrint('[SpeakerEmbedding] Initialized (dim=${_extractor!.dim})');
  }

  /// Extract embedding from Float32 PCM audio at 16 kHz.
  Float32List extractEmbedding(Float32List samples) {
    if (_extractor == null) return Float32List(0);

    final stream = _extractor!.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    stream.inputFinished();

    if (!_extractor!.isReady(stream)) {
      stream.free();
      debugPrint('[SpeakerEmbedding] Not enough audio for embedding');
      return Float32List(0);
    }

    final embedding = _extractor!.compute(stream);
    stream.free();
    return embedding;
  }

  /// Extract embedding from PCM16 little-endian bytes at 16 kHz.
  Float32List extractEmbeddingFromPcm16(Uint8List pcm16Bytes) {
    final samples = _pcm16ToFloat32(pcm16Bytes);
    return extractEmbedding(samples);
  }

  /// Save a Float32List embedding as raw little-endian bytes to file.
  Future<void> saveEmbeddingToFile(
      Float32List embedding, String filePath) async {
    final dir = Directory(filePath.substring(0, filePath.lastIndexOf('/')));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final byteData = ByteData(embedding.length * 4);
    for (var i = 0; i < embedding.length; i++) {
      byteData.setFloat32(i * 4, embedding[i], Endian.little);
    }
    await File(filePath).writeAsBytes(byteData.buffer.asUint8List());
    debugPrint(
        '[SpeakerEmbedding] Saved embedding (${embedding.length} floats) to $filePath');
  }

  /// Load a Float32List embedding from raw little-endian bytes file.
  static Float32List? loadEmbeddingFromFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final bytes = file.readAsBytesSync();
    if (bytes.length % 4 != 0) return null;

    final count = bytes.length ~/ 4;
    final byteData = ByteData.sublistView(bytes);
    final embedding = Float32List(count);
    for (var i = 0; i < count; i++) {
      embedding[i] = byteData.getFloat32(i * 4, Endian.little);
    }
    return embedding;
  }

  void dispose() {
    _extractor?.free();
    _extractor = null;
    debugPrint('[SpeakerEmbedding] Disposed');
  }

  static Float32List _pcm16ToFloat32(Uint8List pcm16) {
    final numSamples = pcm16.length ~/ 2;
    final float32 = Float32List(numSamples);
    final byteData = ByteData.sublistView(pcm16);
    for (var i = 0; i < numSamples; i++) {
      final int16 = byteData.getInt16(i * 2, Endian.little);
      float32[i] = int16 / 32768.0;
    }
    return float32;
  }
}
