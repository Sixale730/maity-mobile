import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:omi/services/local_stt/local_stt_engine.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';

/// Worker isolate entry point for local STT decode + speaker identification.
///
/// Reads 5-second PCM16 chunk files from disk (written by [AudioChunkWriter]),
/// decodes them through [LocalSttEngine] (sherpa_onnx VAD + OfflineRecognizer),
/// and returns segment results. All FFI work runs in this isolate, keeping the
/// main isolate free for UI rendering.
///
/// ## Protocol (tagged lists)
///
/// **Commands (main → worker):**
/// - `['init', String modelPath, String? speakerModelPath, Uint8List? userEmbeddingBytes, String? modelTypeName, double? maxSpeechDuration]` — initialize engine + optional speaker ID
/// - `['process_chunk', String filePath, String chunkId, double offsetSeconds]` — read PCM16 file, decode, return results
/// - `['flush']` — process remaining VAD tail
/// - `['shutdown']` — dispose engine and exit
///
/// **Responses (worker → main):**
/// - `['ready']` — engine initialized
/// - `['error', String message, String? stackTrace]` — error occurred
/// - `['chunk_result', String chunkId, String? jsonSegments, bool vadSpeechActive]` — chunk decoded
/// - `['flushed', String? jsonSegments]` — flush complete
/// - `['vad_state', bool isSpeechActive]` — emitted on VAD state transitions during processing
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
        final maxSpeechDuration =
            message.length > 5 ? message[5] as double? : null;
        worker.handleInit(modelPath, speakerModelPath, userEmbeddingBytes,
            modelTypeName, maxSpeechDuration);
      case 'process_chunk':
        final filePath = message[1] as String;
        final chunkId = message[2] as String;
        final offsetSeconds = message[3] as double;
        worker.handleProcessChunk(filePath, chunkId, offsetSeconds);
      case 'flush':
        worker.handleFlush();
      case 'shutdown':
        worker.handleShutdown();
        workerReceivePort.close();
    }
  });
}

/// Internal worker state — manages engine and speaker ID.
class _SttWorker {
  final SendPort _mainSendPort;
  final LocalSttEngine _engine = LocalSttEngine();

  // Speaker identification (nullable = disabled)
  sherpa.SpeakerEmbeddingExtractor? _speakerExtractor;
  sherpa.SpeakerEmbeddingManager? _speakerManager;
  bool _speakerIdEnabled = false;

  static const String _userName = 'user';

  /// Cosine similarity threshold for CAM++ speaker verification.
  static const double _speakerThreshold = 0.45;

  /// Minimum samples for reliable embedding (~0.5s at 16 kHz).
  static const int _minSamplesForSpeakerId = 8000;

  /// Track previous VAD state to only emit on transitions.
  bool _lastVadState = false;

  _SttWorker(this._mainSendPort);

  Future<void> handleInit(
    String modelPath, [
    String? speakerModelPath,
    Uint8List? userEmbeddingBytes,
    String? modelTypeName,
    double? maxSpeechDuration,
  ]) async {
    try {
      final modelType = modelTypeName != null
          ? LocalSttModelType.fromString(modelTypeName)
          : LocalSttModelType.parakeet;
      await _engine.initialize(modelPath,
          modelType: modelType,
          maxSpeechDuration: maxSpeechDuration ?? 30.0);

      // Initialize speaker ID if both model and embedding are available
      if (speakerModelPath != null &&
          speakerModelPath.isNotEmpty &&
          userEmbeddingBytes != null &&
          userEmbeddingBytes.length == 192 * 4) {
        _initSpeakerId(speakerModelPath, userEmbeddingBytes);
      }

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
      print(
          '[SttWorker] Speaker ID initialized (dim=${_speakerExtractor!.dim})');
    } catch (e) {
      print(
          '[SttWorker] Speaker ID init failed: $e — falling back to no speaker ID');
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

  /// Process a PCM16 chunk file from disk.
  ///
  /// Reads the file, converts PCM16 → Float32, runs VAD + decode,
  /// applies timestamp offset, runs speaker ID, and returns results.
  void handleProcessChunk(
      String filePath, String chunkId, double offsetSeconds) {
    try {
      // Read PCM16 file from disk
      final pcm16 = File(filePath).readAsBytesSync();
      print(
          '[SttWorker] Processing chunk $chunkId: ${pcm16.length} bytes '
          '(${(pcm16.length / 32000.0).toStringAsFixed(2)}s audio, '
          'offset ${offsetSeconds.toStringAsFixed(1)}s)');

      // Convert PCM16 to Float32 and decode
      final samples = _pcm16ToFloat32(Uint8List.fromList(pcm16));
      final results = _engine.processAudio(samples);

      final vadActive = _engine.isSpeechDetected;

      // Emit VAD state transition
      if (vadActive != _lastVadState) {
        _lastVadState = vadActive;
        _mainSendPort.send(['vad_state', vadActive]);
      }

      if (results.isNotEmpty) {
        // Apply timestamp offset so segments have absolute times.
        // LocalSttResult fields are final, so we adjust in _encodeResults.

        for (final r in results) {
          print(
              '[SttWorker] Result: "${r.text}" '
              '(${r.startTime.toStringAsFixed(2)}-${r.endTime.toStringAsFixed(2)}s)');
        }

        final json = _encodeResults(results, offsetSeconds: offsetSeconds);
        _mainSendPort.send(['chunk_result', chunkId, json, vadActive]);
      } else {
        _mainSendPort.send(['chunk_result', chunkId, null, vadActive]);
      }
    } catch (e, trace) {
      print('[SttWorker] handleProcessChunk ERROR: $e');
      _mainSendPort.send(['error', e.toString(), trace.toString()]);
      // Still send chunk_result so the queue manager can proceed
      _mainSendPort.send(['chunk_result', chunkId, null, false]);
    }
  }

  void handleFlush() {
    try {
      // Flush VAD tail to catch speech at the end of recording
      final flushed = _engine.flush();

      final vadActive = _engine.isSpeechDetected;
      if (vadActive != _lastVadState) {
        _lastVadState = vadActive;
        _mainSendPort.send(['vad_state', vadActive]);
      }

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
    _speakerExtractor?.free();
    _speakerManager?.free();
    _speakerExtractor = null;
    _speakerManager = null;
    _speakerIdEnabled = false;
    _engine.dispose();
  }

  /// Encode results as JSON segment array.
  ///
  /// When [offsetSeconds] > 0, timestamps are shifted so they become
  /// absolute offsets from the start of the recording (chunk N starts
  /// at N * 5 seconds).
  String _encodeResults(List<LocalSttResult> results, {double offsetSeconds = 0}) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    var index = 0;

    final segmentsJson = results.map((r) {
      final start = r.startTime + offsetSeconds;
      final end = r.endTime + offsetSeconds;
      final segmentId =
          '${timestamp}_${start.toStringAsFixed(2)}_$index';
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
        'start': start,
        'end': end,
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
