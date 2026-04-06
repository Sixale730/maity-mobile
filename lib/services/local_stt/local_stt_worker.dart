import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:omi/services/audio/audio_processing_utils.dart' as audio;
import 'package:omi/services/audio/pitch_utils.dart' as pitch;
import 'package:omi/services/audio/spectral_utils.dart' as spectral;
import 'package:omi/services/local_stt/local_stt_engine.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/speaker/multi_signal_scorer.dart' as scorer;
import 'package:omi/services/speaker/speaker_types.dart';

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
        final numThreads =
            message.length > 6 ? message[6] as int? : null;
        worker.handleInit(modelPath, speakerModelPath, userEmbeddingBytes,
            modelTypeName, maxSpeechDuration, numThreads);
      case 'process_chunk':
        final filePath = message[1] as String;
        final chunkId = message[2] as String;
        final offsetSeconds = message[3] as double;
        worker.handleProcessChunk(filePath, chunkId, offsetSeconds);
      case 'send_audio':
        worker.handleSendAudio(message[1] as Uint8List);
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

  /// Cosine similarity threshold for CAM++ 512-dim speaker verification.
  /// Higher = more strict. 0.6 rejects most non-user voices while accepting
  /// the enrolled user across different recording conditions.
  static const double _speakerThreshold = 0.6;

  /// Minimum samples for reliable embedding (~0.5s at 16 kHz).
  static const int _minSamplesForSpeakerId = 8000;

  /// Track previous VAD state to only emit on transitions.
  bool _lastVadState = false;

  // Multi-signal scorer state
  Float32List? _userEmbedding;
  AcousticProfile? _acousticProfile;
  bool _prevIsUser = false;
  double _prevConfidence = 0.0;
  double _prevEndTime = 0.0;

  /// Audio accumulated from high-confidence user segments for lazy profile building.
  final List<Float32List> _profileSamples = [];
  static const int _profileSamplesNeeded = 5;
  static const double _profileEmbeddingThreshold = 0.65;

  _SttWorker(this._mainSendPort);

  Future<void> handleInit(
    String modelPath, [
    String? speakerModelPath,
    Uint8List? userEmbeddingBytes,
    String? modelTypeName,
    double? maxSpeechDuration,
    int? numThreads,
  ]) async {
    try {
      final modelType = modelTypeName != null
          ? LocalSttModelType.fromString(modelTypeName)
          : LocalSttModelType.parakeet;
      await _engine.initialize(modelPath,
          modelType: modelType,
          maxSpeechDuration: maxSpeechDuration ?? 30.0,
          numThreads: numThreads ?? 2);

      // Initialize speaker ID if both model and embedding are available
      if (speakerModelPath != null &&
          speakerModelPath.isNotEmpty &&
          userEmbeddingBytes != null &&
          userEmbeddingBytes.length % 4 == 0 &&
          userEmbeddingBytes.isNotEmpty) {
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
      final dim = embeddingBytes.length ~/ 4;
      final embedding = Float32List(dim);
      for (var i = 0; i < dim; i++) {
        embedding[i] = byteData.getFloat32(i * 4, Endian.little);
      }

      _speakerManager!.add(name: _userName, embedding: embedding);
      _userEmbedding = Float32List.fromList(embedding);
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

  /// Score a speech segment for user/non-user classification.
  ///
  /// Returns fused confidence score and binary decision. Uses multi-signal
  /// fusion when an [AcousticProfile] is available, falls back to embedding-only
  /// scoring during the first few segments while the profile is being built.
  ({bool isUser, double confidence, double energyDb}) _scoreSpeaker(
      Float32List samples, double durationSec, double startTime) {
    final energyDb = audio.computeRmsDb(samples);

    if (!_speakerIdEnabled || _userEmbedding == null) {
      return (isUser: true, confidence: 1.0, energyDb: energyDb);
    }

    try {
      final stream = _speakerExtractor!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      stream.inputFinished();

      if (!_speakerExtractor!.isReady(stream)) {
        stream.free();
        print('[SttWorker] Speaker ID: not enough audio, defaulting to user');
        return (isUser: true, confidence: 1.0, energyDb: energyDb);
      }

      final embedding = _speakerExtractor!.compute(stream);
      stream.free();

      if (embedding.isEmpty) {
        return (isUser: true, confidence: 1.0, energyDb: energyDb);
      }

      // Compute embedding similarity
      final embeddingScore =
          audio.cosineSimilarity(embedding, _userEmbedding!);

      bool isUser;
      double confidence;

      if (_acousticProfile != null) {
        // Full 5-signal fused scoring
        final gap = startTime - _prevEndTime;
        final result = scorer.computeFusedScoreWithDiagnostics(
          samples: samples,
          embeddingScore: embeddingScore,
          acousticProfile: _acousticProfile!,
          durationSec: durationSec,
          hasEmbedding: true,
          prevIsUser: _prevIsUser,
          prevConfidence: _prevConfidence,
          prevGapSec: gap > 0 ? gap : double.infinity,
        );
        isUser = result.score >= kUserThreshold;
        confidence = result.score;
        print('[SttWorker] Fused score: ${result.score.toStringAsFixed(3)} '
            '(emb=${embeddingScore.toStringAsFixed(2)}, '
            'ene=${result.energyScore.toStringAsFixed(2)}, '
            'pit=${result.pitchScore.toStringAsFixed(2)}) '
            '→ ${isUser ? "USER" : "OTHER"}');
      } else {
        // Fallback: embedding-only scoring while building profile
        isUser = embeddingScore >= _speakerThreshold;
        confidence = embeddingScore;
        print('[SttWorker] Embedding score: ${embeddingScore.toStringAsFixed(3)} '
            '→ ${isUser ? "USER" : "OTHER"} (profile pending)');

        // Accumulate samples for lazy acoustic profile building
        if (isUser && embeddingScore >= _profileEmbeddingThreshold) {
          _profileSamples.add(Float32List.fromList(samples));
          if (_profileSamples.length >= _profileSamplesNeeded) {
            _buildAcousticProfile();
          }
        }
      }

      // Update state for temporal boost on next segment
      _prevIsUser = isUser;
      _prevConfidence = confidence;
      _prevEndTime = startTime + durationSec;

      return (isUser: isUser, confidence: confidence, energyDb: energyDb);
    } catch (e) {
      print('[SttWorker] Speaker scoring error: $e');
      return (isUser: true, confidence: 1.0, energyDb: energyDb);
    }
  }

  /// Build acoustic profile from accumulated user samples.
  void _buildAcousticProfile() {
    // Concatenate all accumulated samples
    final totalLength =
        _profileSamples.fold<int>(0, (sum, s) => sum + s.length);
    final combined = Float32List(totalLength);
    var offset = 0;
    for (final s in _profileSamples) {
      combined.setRange(offset, offset + s.length, s);
      offset += s.length;
    }
    _profileSamples.clear();

    // Extract acoustic features
    final f0Stats = pitch.estimateF0Stats(combined);
    final energyDbMean = audio.computeRmsDb(combined);
    final spectralFeatures = spectral.extractSpectralFeatures(combined);

    _acousticProfile = AcousticProfile(
      f0Mean: f0Stats?.mean ?? 150.0,
      f0Std: f0Stats?.std ?? 40.0,
      energyDbMean: energyDbMean,
      spectralCentroid: spectralFeatures?.centroid ?? 1500.0,
      spectralSlope: spectralFeatures?.slope ?? 0.0,
    );

    print('[SttWorker] Acoustic profile built: '
        'f0=${_acousticProfile!.f0Mean.toStringAsFixed(0)}Hz, '
        'energy=${_acousticProfile!.energyDbMean.toStringAsFixed(1)}dB, '
        'centroid=${_acousticProfile!.spectralCentroid.toStringAsFixed(0)}Hz');
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

  /// Process streaming PCM16 audio (used by speech profile enrollment).
  /// Unlike handleProcessChunk which reads from disk, this receives bytes
  /// directly via SendPort for low-latency live transcription.
  void handleSendAudio(Uint8List pcm16Bytes) {
    try {
      final samples = _pcm16ToFloat32(pcm16Bytes);
      final results = _engine.processAudio(samples);

      final vadActive = _engine.isSpeechDetected;
      if (vadActive != _lastVadState) {
        _lastVadState = vadActive;
        _mainSendPort.send(['vad_state', vadActive]);
      }

      if (results.isNotEmpty) {
        final json = _encodeResults(results);
        _mainSendPort.send(['chunk_result', 'stream', json, vadActive]);
      }
    } catch (e, trace) {
      print('[SttWorker] handleSendAudio ERROR: $e');
      _mainSendPort.send(['error', e.toString(), trace.toString()]);
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

      // Speaker scoring per segment (multi-signal or embedding-only fallback)
      bool isUser = true;
      String speaker = 'SPEAKER_0';
      int speakerId = 0;
      double confidence = 1.0;
      double energyDb = audio.kMinRmsDb;
      final durationSec = end - start;

      if (_speakerIdEnabled &&
          r.samples != null &&
          r.samples!.length >= _minSamplesForSpeakerId) {
        final result = _scoreSpeaker(r.samples!, durationSec, start);
        isUser = result.isUser;
        confidence = result.confidence;
        energyDb = result.energyDb;
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
        'confidence': confidence,
        'energy_db': energyDb,
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
