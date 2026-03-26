import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:omi/services/local_stt/local_stt_engine.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';

/// Worker isolate entry point for local STT decode + speaker identification.
///
/// Receives PCM16 audio via [SendPort], buffers it, and periodically flushes
/// through [LocalSttEngine] (sherpa_onnx VAD + OfflineRecognizer). All FFI
/// work runs in this isolate, keeping the main isolate free for UI rendering.
///
/// ## Protocol (tagged lists)
///
/// **Commands (main → worker):**
/// - `['init', String modelPath, String? speakerModelPath, Uint8List? userEmbeddingBytes, String? modelTypeName]` — initialize engine + optional speaker ID
/// - `['audio', Uint8List pcm16Bytes]` — feed audio
/// - `['flush']` — process remaining audio + VAD tail
/// - `['shutdown']` — dispose engine and exit
///
/// **Responses (worker → main):**
/// - `['ready']` — engine initialized
/// - `['error', String message, String? stackTrace]` — error occurred
/// - `['results', String jsonSegments]` — decoded segments
/// - `['flushed', String? jsonSegments]` — flush complete
@pragma('vm:entry-point')
void workerEntryPoint(SendPort mainSendPort) {
  final workerReceivePort = ReceivePort();
  mainSendPort.send(workerReceivePort.sendPort);

  final worker = _SttWorker(mainSendPort);

  workerReceivePort.listen((message) {
    if (message is! List || message.isEmpty) return;

    final command = message[0] as String;
    switch (command) {
      case 'init':
        final modelPath = message[1] as String;
        final speakerModelPath =
            message.length > 2 ? message[2] as String? : null;
        final userEmbeddingBytes =
            message.length > 3 ? message[3] as Uint8List? : null;
        final modelTypeName =
            message.length > 4 ? message[4] as String? : null;
        worker.handleInit(
            modelPath, speakerModelPath, userEmbeddingBytes, modelTypeName);
      case 'audio':
        worker.handleAudio(message[1] as Uint8List);
      case 'flush':
        worker.handleFlush();
      case 'shutdown':
        worker.handleShutdown();
        workerReceivePort.close();
    }
  });
}

/// Internal worker state — manages engine, buffer, periodic flush, and speaker ID.
class _SttWorker {
  final SendPort _mainSendPort;
  final LocalSttEngine _engine = LocalSttEngine();
  final List<Uint8List> _audioFrames = [];
  Timer? _flushTimer;
  bool _isProcessing = false;

  // Speaker identification (nullable = disabled)
  sherpa.SpeakerEmbeddingExtractor? _speakerExtractor;
  sherpa.SpeakerEmbeddingManager? _speakerManager;
  bool _speakerIdEnabled = false;

  static const String _userName = 'user';

  /// Cosine similarity threshold for CAM++ speaker verification.
  /// Lower = more permissive (fewer false negatives, more false positives).
  /// Typical range for CAM++ 16k: 0.4–0.55.
  static const double _speakerThreshold = 0.45;

  /// Minimum samples for reliable embedding (~0.5s at 16 kHz).
  static const int _minSamplesForSpeakerId = 8000;

  /// Flush every 2 seconds (reduced from 3s for smaller chunks = faster decode).
  static const Duration _flushInterval = Duration(seconds: 2);

  /// Minimum bytes before flushing (~0.5s of 16 kHz 16-bit mono).
  static const int _minBufferBytes = 16000;

  _SttWorker(this._mainSendPort);

  Future<void> handleInit(
    String modelPath, [
    String? speakerModelPath,
    Uint8List? userEmbeddingBytes,
    String? modelTypeName,
  ]) async {
    try {
      final modelType = modelTypeName != null
          ? LocalSttModelType.fromString(modelTypeName)
          : LocalSttModelType.parakeet;
      await _engine.initialize(modelPath, modelType: modelType);

      // Initialize speaker ID if both model and embedding are available
      if (speakerModelPath != null &&
          speakerModelPath.isNotEmpty &&
          userEmbeddingBytes != null &&
          userEmbeddingBytes.length == 192 * 4) {
        _initSpeakerId(speakerModelPath, userEmbeddingBytes);
      }

      _startFlushTimer();
      _mainSendPort.send(['ready']);
    } catch (e, trace) {
      _mainSendPort.send(['error', e.toString(), trace.toString()]);
    }
  }

  void _initSpeakerId(String modelPath, Uint8List embeddingBytes) {
    try {
      final config = sherpa.SpeakerEmbeddingExtractorConfig(
        model: modelPath,
        numThreads: 1,
        debug: false,
        provider: 'cpu',
      );
      _speakerExtractor = sherpa.SpeakerEmbeddingExtractor(config: config);

      _speakerManager =
          sherpa.SpeakerEmbeddingManager(_speakerExtractor!.dim);

      // Deserialize user embedding from raw little-endian Float32 bytes
      final byteData = ByteData.sublistView(embeddingBytes);
      final embedding = Float32List(192);
      for (var i = 0; i < 192; i++) {
        embedding[i] = byteData.getFloat32(i * 4, Endian.little);
      }

      _speakerManager!.add(name: _userName, embedding: embedding);
      _speakerIdEnabled = true;
      // debugPrint not available in isolate, use print for debugging
      print('[SttWorker] Speaker ID initialized (dim=${_speakerExtractor!.dim})');
    } catch (e) {
      print('[SttWorker] Speaker ID init failed: $e — falling back to no speaker ID');
      _speakerExtractor?.free();
      _speakerManager?.free();
      _speakerExtractor = null;
      _speakerManager = null;
      _speakerIdEnabled = false;
    }
  }

  /// Identify whether a speech segment belongs to the enrolled user.
  bool _identifySpeaker(Float32List samples) {
    if (!_speakerIdEnabled) return true;

    try {
      final stream = _speakerExtractor!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      stream.inputFinished();

      if (!_speakerExtractor!.isReady(stream)) {
        stream.free();
        return true; // Not enough audio, default to user
      }

      final embedding = _speakerExtractor!.compute(stream);
      stream.free();

      if (embedding.isEmpty) return true;

      final name = _speakerManager!.search(
        embedding: embedding,
        threshold: _speakerThreshold,
      );

      return name == _userName;
    } catch (e) {
      return true; // On error, default to user
    }
  }

  void handleAudio(Uint8List pcm16Bytes) {
    _audioFrames.add(pcm16Bytes);
  }

  void handleFlush() {
    try {
      // Process remaining buffered audio
      if (_audioFrames.isNotEmpty) {
        _processBuffer();
      }

      // Flush VAD tail to catch speech at the end
      final flushed = _engine.flush();
      if (flushed.isNotEmpty) {
        final json = _encodeResults(flushed);
        _mainSendPort.send(['flushed', json]);
      } else {
        _mainSendPort.send(['flushed', null]);
      }
    } catch (e, trace) {
      _mainSendPort.send(['error', e.toString(), trace.toString()]);
      _mainSendPort.send(['flushed', null]);
    }
  }

  void handleShutdown() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _audioFrames.clear();
    _speakerExtractor?.free();
    _speakerManager?.free();
    _speakerExtractor = null;
    _speakerManager = null;
    _speakerIdEnabled = false;
    _engine.dispose();
  }

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      _flushBuffer();
    });
  }

  void _flushBuffer() {
    if (_audioFrames.isEmpty || !_engine.isInitialized) return;

    final totalBytes =
        _audioFrames.fold<int>(0, (sum, frame) => sum + frame.length);
    if (totalBytes < _minBufferBytes || _isProcessing) return;

    _processBuffer();
  }

  void _processBuffer() {
    if (_audioFrames.isEmpty) return;
    _isProcessing = true;

    try {
      final frames = List<Uint8List>.from(_audioFrames);
      _audioFrames.clear();

      // Concatenate PCM16 bytes
      final totalLength =
          frames.fold<int>(0, (sum, frame) => sum + frame.length);
      final pcm16 = Uint8List(totalLength);
      int offset = 0;
      for (final frame in frames) {
        pcm16.setRange(offset, offset + frame.length, frame);
        offset += frame.length;
      }

      // Convert PCM16 to Float32 and decode
      final samples = _pcm16ToFloat32(pcm16);
      final results = _engine.processAudio(samples);

      if (results.isNotEmpty) {
        final json = _encodeResults(results);
        _mainSendPort.send(['results', json]);
      }
    } catch (e, trace) {
      _mainSendPort.send(['error', e.toString(), trace.toString()]);
    } finally {
      _isProcessing = false;
    }
  }

  /// Encode results as JSON segment array.
  ///
  /// Timestamps come directly from the VAD's cumulative sample index
  /// (segment.start / sampleRate) — they are already absolute offsets
  /// from the start of the recording. No additional offset is needed.
  String _encodeResults(List<LocalSttResult> results) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    var index = 0;

    final segmentsJson = results.map((r) {
      final segmentId =
          '${timestamp}_${r.startTime.toStringAsFixed(2)}_$index';
      index++;

      // Speaker identification per segment
      bool isUser = true;
      String speaker = 'SPEAKER_0';
      int speakerId = 0;

      if (_speakerIdEnabled &&
          r.samples != null &&
          r.samples!.length >= _minSamplesForSpeakerId) {
        isUser = _identifySpeaker(r.samples!);
        if (!isUser) {
          speaker = 'SPEAKER_1';
          speakerId = 1;
        }
      }

      return {
        'id': segmentId,
        'text': r.text,
        'speaker': speaker,
        'speaker_id': speakerId,
        'is_user': isUser,
        'start': r.startTime,
        'end': r.endTime,
      };
    }).toList();

    return jsonEncode(segmentsJson);
  }

  /// Convert PCM16 little-endian bytes to Float32 samples normalized to [-1, 1].
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
