import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:omi/services/audio/audio_processing_utils.dart' as audio;
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
  /// XNNPACK gives 2-3x speedup on Android ARM via optimized CPU kernels.
  /// iOS stays on 'cpu' — CoreML causes OOM (2.9GB on iPhone).
  static String get _preferredProvider =>
      Platform.isAndroid ? 'xnnpack' : 'cpu';

  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  bool _isInitialized = false;
  double _maxSpeechDuration = 30.0;
  LocalSttModelType _modelType = LocalSttModelType.parakeet;

  /// Cumulative samples fed since last segment was drained.
  /// Used for application-level force-flush on transducer models (Parakeet).
  /// Encoder-decoder models (Canary) skip force-flush: they need clean
  /// speech segments from the VAD and produce "(EMPTY)" on noise.
  /// The VAD's native maxSpeechDuration already handles long speech
  /// by adjusting thresholds (→0.9) and minSilence (→0.1s).
  /// Refs: sherpa-onnx PR #1099 (flush API), Silero VAD Issue #518
  int _samplesSinceLastDrain = 0;

  /// Recognizer recycling: sherpa_onnx leaks ~1MB native memory per decode().
  /// Recreating the recognizer every [_recycleInterval] inferences reclaims it.
  int _inferenceCount = 0;
  static const int _recycleInterval = 50;
  sherpa.OfflineRecognizerConfig? _recognizerConfig;

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
    int numThreads = 2,
  }) async {
    if (_isInitialized) return;
    _maxSpeechDuration = maxSpeechDuration;
    _modelType = modelType;

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
            numThreads: numThreads,
            debug: false,
            provider: _preferredProvider,
          ),
          decodingMethod: 'greedy_search',
        );
      } else if (modelType == LocalSttModelType.canary) {
        // Canary 180M Flash: OfflineCanaryModelConfig (en/es/de/fr)
        // Requires explicit srcLang/tgtLang (no auto-detect).
        // usePnc enables punctuation & capitalization via <|pnc|> decoder token.
        // decodingMethod is ignored — Canary uses hardcoded greedy (argmax) in C++.
        // Ref: sherpa-onnx/csrc/offline-recognizer-canary-impl.h
        config = sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            canary: sherpa.OfflineCanaryModelConfig(
              encoder: '$modelDir/encoder.int8.onnx',
              decoder: '$modelDir/decoder.int8.onnx',
              srcLang: 'es',
              tgtLang: 'es',
              usePnc: true,
            ),
            tokens: '$modelDir/tokens.txt',
            numThreads: numThreads,
            debug: false,
            provider: _preferredProvider,
          ),
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
            numThreads: numThreads,
            debug: false,
            provider: _preferredProvider,
          ),
          decodingMethod: 'greedy_search',
        );
      }

      _recognizerConfig = config;
      _recognizer = sherpa.OfflineRecognizer(config);
      _inferenceCount = 0;
      debugPrint('[LocalSttEngine] Using model type: ${modelType.name}, '
          'maxSpeechDuration: ${maxSpeechDuration}s, numThreads: $numThreads');

      // Configure Silero VAD.
      // minSpeechDuration 0.3s: autoresearch (Apr 2026) found 0.8s was discarding
      // valid short speech segments (interjections, confirmations like "sí", "claro").
      // Lowering to 0.3s reduced WER from 9.10% → 7.32% (-19.6% relative) on a
      // 32-clip Mexican Spanish corpus. Parakeet TDT decodes 0.3s segments reliably
      // with the pre-pad silence providing clean onset for FastConformer.
      const minSpeech = 0.3;
      // Canary benefits from faster silence detection (0.3s) for natural
      // conversational segmentation. Parakeet/Moonshine use 1.0s to prevent
      // premature mid-utterance cuts — accumulated speech decodes better than
      // short isolated VAD segments with no clean onset.
      final minSilence = modelType == LocalSttModelType.canary ? 0.3 : 1.0;
      final vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: '$modelDir/silero_vad.onnx',
          minSpeechDuration: minSpeech,
          minSilenceDuration: minSilence,
          threshold: 0.5,
          windowSize: 512,
          maxSpeechDuration: maxSpeechDuration,
        ),
        sampleRate: sampleRate,
        numThreads: 1,
        provider: _preferredProvider,
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

    // Force-flush safety net: if continuous speech exceeds maxSpeechDuration
    // without natural pauses, force a segment boundary. sherpa-onnx's native
    // mechanism (threshold→0.9, minSilence→0.1s) runs first at maxSpeechDuration;
    // this flush() is the hard cap if it still can't find a pause.
    // Parakeet (transducer, 20s default): tolerates arbitrary cuts, no "(EMPTY)".
    // Canary (encoder-decoder, 10s default): may produce "(EMPTY)" on cuts.
    // Refs: sherpa-onnx c-api.cc (default 20s), Issue #2148, Silero VAD #155
    if (_vad!.isDetected()) {
      _samplesSinceLastDrain += samples.length;
    }
    final maxSamples = (_maxSpeechDuration * sampleRate).toInt();
    if (_samplesSinceLastDrain >= maxSamples) {
      debugPrint('[LocalSttEngine] Force-flushing VAD after '
          '${(_samplesSinceLastDrain / sampleRate).toStringAsFixed(1)}s of speech');
      _vad!.flush();
      _samplesSinceLastDrain = 0;
      // NOTE: Do NOT call _vad!.reset() here — it clears the LSTM state and
      // circular buffer, causing the VAD to need ~4s warmup to re-detect speech.
      // The VAD maintains valid state across flush() calls.
    }

    // Drain all segments (force-flushed + naturally-detected)
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
      _vad!.pop();
      segCount++;

      try {
        final startTime = segment.start.toDouble() / sampleRate;
        final endTime =
            (segment.start + segment.samples.length).toDouble() / sampleRate;
        final durationMs = ((endTime - startTime) * 1000).toInt();

        debugPrint('[LocalSttEngine] VAD segment #$segCount: ${segment.samples.length} samples (${durationMs}ms), start=${startTime.toStringAsFixed(2)}s');

        // Skip short noise bursts: segments < 0.8s with energy below -40dB
        if (durationMs < 800) {
          final rmsDb = audio.computeRmsDb(segment.samples);
          if (rmsDb < -40.0) {
            debugPrint('[LocalSttEngine] Skipping low-energy segment: ${durationMs}ms, ${rmsDb.toStringAsFixed(1)}dB');
            continue;
          }
        }

        // Append silence padding so the decoder sees end-of-utterance.
        // Canary needs more padding (0.5s) than transducer models (0.3s)
        // because encoder-decoder attention needs clear end-of-utterance signal.
        final paddedSamples = _padWithSilence(segment.samples, _modelType);

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

        // Recycle recognizer to prevent native memory leak (~1MB per decode)
        _maybeRecycleRecognizer();

        // Truncate decoder repetition loops (e.g. "mil doce mil doce mil doce...")
        text = _truncateRepetitions(text);

        // Discard fully hallucinated segments (word/bigram/phrase repetition)
        if (_isHallucination(text)) {
          debugPrint('[LocalSttEngine] Discarding hallucinated segment: "$text"');
          continue;
        }

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
    }

    return results;
  }

  /// Recycle the recognizer to reclaim native memory.
  ///
  /// sherpa_onnx leaks ~1MB per decode() call. Recreating every
  /// [_recycleInterval] inferences prevents unbounded growth.
  /// NEVER recycle with less than 50 inferences — causes context loss.
  void _maybeRecycleRecognizer() {
    _inferenceCount++;
    if (_inferenceCount < _recycleInterval) return;
    if (_recognizerConfig == null) return;

    _recognizer?.free();
    _recognizer = sherpa.OfflineRecognizer(_recognizerConfig!);
    _inferenceCount = 0;
    debugPrint('[LocalSttEngine] Recycled recognizer after $_recycleInterval inferences');
  }

  /// Pad audio with silence at BOTH sides so the encoder-decoder sees clean
  /// utterance boundaries.
  ///
  /// Pre-pad: silence before speech gives the encoder a clean onset boundary
  /// (silence→speech transition). Without this, force-flushed segments that
  /// start mid-speech cause Canary to decode as "(EMPTY)".
  ///
  /// Post-pad: silence after speech signals end-of-utterance to the decoder.
  ///
  /// Refs: NVIDIA Canary pads symmetrically to 1s minimum.
  ///       Whisper expects zero-padded boundaries (trained on 30s chunks).
  static Float32List _padWithSilence(Float32List samples, LocalSttModelType modelType) {
    const prePad = 6400;  // 0.4s all models: gives FastConformer a clear silence→speech onset
    final postPad = modelType == LocalSttModelType.canary ? 8000 : 4800; // 0.5s / 0.3s
    final padded = Float32List(prePad + samples.length + postPad);
    padded.setRange(prePad, prePad + samples.length, samples);
    // Pre-pad and post-pad are already 0.0 (Float32List default)
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
        debugPrint('[LocalSttEngine] Truncated $repeats repetitions of "$pattern"');
        return truncated;
      }
    }

    return text;
  }

  /// Detect fully hallucinated segments that _truncateRepetitions misses.
  ///
  /// Three detectors:
  /// 1. Single word > 60% of text
  /// 2. Single bigram > 50% of text
  /// 3. Phrase of 3-5 words repeated 4+ times anywhere
  ///
  /// Only checks segments with >= 15 words (short segments are fine).
  static bool _isHallucination(String text) {
    final words = text.toLowerCase().split(RegExp(r'\s+'));
    if (words.length < 15) return false;

    // Detector 1: single word > 60% of text
    final wordCounts = <String, int>{};
    for (final w in words) {
      wordCounts[w] = (wordCounts[w] ?? 0) + 1;
    }
    if (wordCounts.values.any((c) => c / words.length > 0.60)) return true;

    // Detector 2: single bigram > 50%
    if (words.length >= 6) {
      final bigrams = <String, int>{};
      for (var i = 0; i < words.length - 1; i++) {
        final bg = '${words[i]} ${words[i + 1]}';
        bigrams[bg] = (bigrams[bg] ?? 0) + 1;
      }
      if (bigrams.values.any((c) => c / (words.length - 1) > 0.50)) {
        return true;
      }
    }

    // Detector 3: phrase of 3-5 words repeated 4+ times
    for (var phraseLen = 3; phraseLen <= 5; phraseLen++) {
      if (words.length < phraseLen * 4) continue;
      final phrases = <String, int>{};
      for (var i = 0; i <= words.length - phraseLen; i++) {
        final phrase = words.sublist(i, i + phraseLen).join(' ');
        phrases[phrase] = (phrases[phrase] ?? 0) + 1;
      }
      if (phrases.values.any((c) => c >= 4)) return true;
    }

    return false;
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
    _recognizerConfig = null;
    _inferenceCount = 0;
    _isInitialized = false;
    debugPrint('[LocalSttEngine] Disposed');
  }
}
