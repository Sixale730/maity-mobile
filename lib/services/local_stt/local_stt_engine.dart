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
  double _maxSpeechDuration = 30.0;

  /// Cumulative samples fed since last segment was drained.
  /// Used for application-level force-flush: sherpa_onnx's native
  /// maxSpeechDuration only makes the VAD more aggressive at finding
  /// pauses (threshold→0.9, minSilence→0.1s) but does NOT hard-split
  /// continuous speech. This counter + flush() guarantees segment
  /// emission at bounded intervals.
  /// Refs: sherpa-onnx PR #1099 (flush API), Silero VAD Issue #518
  int _samplesSinceLastDrain = 0;

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
    _maxSpeechDuration = maxSpeechDuration;

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
    _samplesSinceLastDrain += samples.length;

    // Force-flush: the native VAD's maxSpeechDuration only raises the
    // detection threshold but won't hard-split continuous speech without
    // pauses. Calling flush() forces emission of any accumulated speech,
    // guaranteeing segments at bounded intervals for real-time display.
    final maxSamples = (_maxSpeechDuration * sampleRate).toInt();
    if (_samplesSinceLastDrain >= maxSamples) {
      debugPrint('[LocalSttEngine] Force-flushing VAD after '
          '${(_samplesSinceLastDrain / sampleRate).toStringAsFixed(1)}s');
      _vad!.flush();
      _samplesSinceLastDrain = 0;
    }

    final vadEmpty = _vad!.isEmpty();
    if (_processCallCount % 5 == 1 || !vadEmpty) {
      debugPrint('[LocalSttEngine] processAudio #$_processCallCount: ${samples.length} samples, vadEmpty=$vadEmpty');
    }

    final results = _drainSegments();
    if (results.isNotEmpty) {
      _samplesSinceLastDrain = 0;
    }
    return results;
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

        // Append silence padding so the decoder sees end-of-utterance.
        // Without this, encoder-decoder models (Canary) enter repetition
        // loops when audio is truncated mid-speech by force-flush.
        final paddedSamples = _padWithSilence(segment.samples);

        // Decode the speech segment
        final stream = _recognizer!.createStream();
        stream.acceptWaveform(
          samples: paddedSamples,
          sampleRate: sampleRate,
        );
        _recognizer!.decode(stream);

        final result = _recognizer!.getResult(stream);
        var text = result.text.trim();
        stream.free();

        // Truncate decoder repetition loops (e.g. "mil doce mil doce mil doce...")
        text = _truncateRepetitions(text);

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

  /// Pad audio with silence so the decoder detects end-of-utterance.
  /// 0.3s of zeros at 16 kHz = 4800 samples — negligible decode overhead.
  static Float32List _padWithSilence(Float32List samples) {
    const silenceSamples = 4800; // 0.3s at 16 kHz
    final padded = Float32List(samples.length + silenceSamples);
    padded.setRange(0, samples.length, samples);
    // Remaining samples are already 0.0 (Float32List default)
    return padded;
  }

  /// Detect and truncate repetition loops from the decoder output.
  ///
  /// Encoder-decoder models can enter loops when force-flushed mid-speech,
  /// producing text like "mil doce mil doce mil doce mil doce...".
  /// This checks for repeated N-gram patterns at the tail and truncates.
  static String _truncateRepetitions(String text) {
    if (text.isEmpty) return text;
    final words = text.split(' ');
    if (words.length < 6) return text;

    // Check patterns of 1 to 5 words
    for (int patLen = 1; patLen <= 5; patLen++) {
      if (words.length < patLen * 3) continue;

      final pattern = words.sublist(words.length - patLen).join(' ');
      int repeats = 0;
      int pos = words.length - patLen;

      while (pos >= patLen) {
        final chunk = words.sublist(pos - patLen, pos).join(' ');
        if (chunk == pattern) {
          repeats++;
          pos -= patLen;
        } else {
          break;
        }
      }

      // 3+ consecutive repetitions = hallucination, keep first occurrence
      if (repeats >= 3) {
        final truncated = words.sublist(0, pos + patLen).join(' ');
        debugPrint('[LocalSttEngine] Truncated ${repeats} repetitions of "$pattern"');
        return truncated;
      }
    }

    return text;
  }

  /// Whether the VAD is currently detecting speech.
  /// Used by the worker isolate to decide when to emit preview transcriptions.
  bool get isSpeechDetected => _vad?.isDetected() ?? false;

  /// Decode a preview from accumulated speech samples without affecting VAD state.
  ///
  /// Uses the same [OfflineRecognizer] as [_drainSegments] — works identically
  /// with Canary, Parakeet, and Moonshine since the decode API is model-agnostic.
  /// Returns decoded text, or null if too short / empty / failed.
  String? generatePreview(Float32List samples) {
    if (!_isInitialized || _recognizer == null || samples.length < 1600) {
      return null;
    }
    try {
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      _recognizer!.decode(stream);
      final text = _recognizer!.getResult(stream).text.trim();
      stream.free();
      return text.isEmpty ? null : text;
    } catch (e) {
      debugPrint('[LocalSttEngine] Preview decode error: $e');
      return null;
    }
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
