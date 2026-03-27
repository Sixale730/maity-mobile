import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:omi/services/local_stt/local_stt_model_type.dart';

/// Result from a local STT decode operation.
class LocalSttResult {
  final String text;
  final double startTime;
  final double endTime;

  /// Raw VAD segment audio for speaker identification.
  /// Null when speaker ID is not needed.
  final Float32List? samples;

  const LocalSttResult({
    required this.text,
    required this.startTime,
    required this.endTime,
    this.samples,
  });
}

/// Wraps sherpa_onnx OfflineRecognizer + VoiceActivityDetector for local STT.
///
/// Audio is fed via [processAudio] as Float32 PCM at 16 kHz.
/// The VAD detects speech segments and the recognizer decodes them offline.
class LocalSttEngine {
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  static const int sampleRate = 16000;

  /// Initialize the engine with model files located in [modelDir].
  ///
  /// For Parakeet expects: encoder.int8.onnx, decoder.int8.onnx, joiner.int8.onnx, tokens.txt, silero_vad.onnx
  /// For Moonshine expects: preprocess.onnx, encode.int8.onnx, uncached_decode.int8.onnx, cached_decode.int8.onnx, tokens.txt, silero_vad.onnx
  Future<void> initialize(
    String modelDir, {
    LocalSttModelType modelType = LocalSttModelType.parakeet,
    double maxSpeechDuration = 30.0,
  }) async {
    if (_isInitialized) return;

    try {
      sherpa.initBindings();

      final sherpa.OfflineRecognizerConfig config;

      if (modelType == LocalSttModelType.moonshine) {
        // Moonshine v2: merged decoder format (.ort files)
        // Refs: PR #3232, #3245, Issue #3223 — v2 uses encoder + mergedDecoder
        config = sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            moonshine: sherpa.OfflineMoonshineModelConfig(
              preprocessor: '', // empty for v2
              encoder: '$modelDir/encoder_model.ort',
              uncachedDecoder: '', // empty for v2 (merged)
              cachedDecoder: '', // empty for v2 (merged)
              mergedDecoder: '$modelDir/decoder_model_merged.ort',
            ),
            tokens: '$modelDir/tokens.txt',
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
          decodingMethod: 'greedy_search',
        );
      } else if (modelType == LocalSttModelType.canary) {
        // Canary 180M Flash: OfflineCanaryModelConfig (en/es/de/fr)
        // Requires explicit srcLang/tgtLang (no auto-detect)
        config = sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            canary: sherpa.OfflineCanaryModelConfig(
              encoder: '$modelDir/encoder.int8.onnx',
              decoder: '$modelDir/decoder.int8.onnx',
              srcLang: 'es',
              tgtLang: 'es',
            ),
            tokens: '$modelDir/tokens.txt',
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
          decodingMethod: 'greedy_search',
        );
      } else {
        // Parakeet: OfflineTransducerModelConfig (NeMo Transducer)
        config = sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            transducer: sherpa.OfflineTransducerModelConfig(
              encoder: '$modelDir/encoder.int8.onnx',
              decoder: '$modelDir/decoder.int8.onnx',
              joiner: '$modelDir/joiner.int8.onnx',
            ),
            tokens: '$modelDir/tokens.txt',
            modelType: 'nemo_transducer',
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
          decodingMethod: 'greedy_search',
        );
      }

      _recognizer = sherpa.OfflineRecognizer(config);
      debugPrint('[LocalSttEngine] Using model type: ${modelType.name}, maxSpeechDuration: ${maxSpeechDuration}s');

      // Configure Silero VAD
      final vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: '$modelDir/silero_vad.onnx',
          minSpeechDuration: 0.25,
          minSilenceDuration: 0.5,
          threshold: 0.5,
          windowSize: 512,
          maxSpeechDuration: maxSpeechDuration,
        ),
        sampleRate: sampleRate,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      );

      _vad = sherpa.VoiceActivityDetector(
        config: vadConfig,
        bufferSizeInSeconds: 120,
      );

      _isInitialized = true;
      debugPrint('[LocalSttEngine] Initialized successfully');
    } catch (e) {
      debugPrint('[LocalSttEngine] Initialization failed: $e');
      _isInitialized = false;
      rethrow;
    }
  }

  /// Feed audio samples to VAD and decode any detected speech segments.
  ///
  /// [samples] must be Float32 PCM at 16 kHz, normalized to [-1, 1].
  /// Returns a list of decoded results (may be empty if no speech detected).
  int _processCallCount = 0;

  List<LocalSttResult> processAudio(Float32List samples) {
    if (!_isInitialized || _vad == null || _recognizer == null) {
      debugPrint('[LocalSttEngine] processAudio: not initialized!');
      return [];
    }

    _processCallCount++;
    _vad!.acceptWaveform(samples);

    final vadEmpty = _vad!.isEmpty();
    if (_processCallCount % 5 == 1 || !vadEmpty) {
      debugPrint('[LocalSttEngine] processAudio #$_processCallCount: ${samples.length} samples, vadEmpty=$vadEmpty');
    }

    return _drainSegments();
  }

  /// Flush any remaining audio in the VAD buffer and decode residual speech.
  List<LocalSttResult> flush() {
    if (!_isInitialized || _vad == null || _recognizer == null) return [];
    _vad!.flush();
    return _drainSegments();
  }

  /// Drain all queued speech segments from VAD and decode each one.
  List<LocalSttResult> _drainSegments() {
    final results = <LocalSttResult>[];
    int segCount = 0;

    while (!_vad!.isEmpty()) {
      final segment = _vad!.front();
      segCount++;

      try {
        final startTime = segment.start.toDouble() / sampleRate;
        final endTime =
            (segment.start + segment.samples.length).toDouble() / sampleRate;
        final durationMs = ((endTime - startTime) * 1000).toInt();

        debugPrint('[LocalSttEngine] VAD segment #$segCount: ${segment.samples.length} samples (${durationMs}ms), start=${startTime.toStringAsFixed(2)}s');

        // Decode the speech segment
        final stream = _recognizer!.createStream();
        stream.acceptWaveform(
          samples: segment.samples,
          sampleRate: sampleRate,
        );
        _recognizer!.decode(stream);

        final result = _recognizer!.getResult(stream);
        final text = result.text.trim();
        stream.free();

        debugPrint('[LocalSttEngine] Decode result: "${text.isEmpty ? "(EMPTY)" : text}" (${durationMs}ms segment)');

        if (text.isNotEmpty) {
          results.add(LocalSttResult(
            text: text,
            startTime: startTime,
            endTime: endTime,
            samples: Float32List.fromList(segment.samples),
          ));
        }
      } catch (e) {
        debugPrint('[LocalSttEngine] Decode error for segment: $e');
      }

      _vad!.pop();
    }

    return results;
  }

  void dispose() {
    _vad?.free();
    _vad = null;
    _recognizer?.free();
    _recognizer = null;
    _isInitialized = false;
    debugPrint('[LocalSttEngine] Disposed');
  }
}
