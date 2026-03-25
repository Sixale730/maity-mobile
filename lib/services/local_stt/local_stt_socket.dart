import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:omi/services/local_stt/local_stt_engine.dart';
import 'package:omi/services/sockets/pure_socket.dart';

/// IPureSocket adapter that bridges [LocalSttEngine] to the transcription
/// pipeline. Receives PCM16 audio via [send], converts to Float32, buffers,
/// and periodically flushes through the engine. Results are emitted as JSON
/// via [onMessage] in the same segment format the pipeline expects.
///
/// This adapter does NOT require network -- all processing is local.
///
/// NOTE: sherpa_onnx holds native FFI pointers that cannot cross isolate
/// boundaries, so all decoding runs synchronously on the main isolate.
/// For 3-second chunks the decode is typically <200ms on modern devices.
class LocalSttSocket implements IPureSocket {
  final LocalSttEngine _engine;

  PureSocketStatus _status = PureSocketStatus.notConnected;
  IPureSocketListener? _listener;

  Timer? _flushTimer;
  final List<Uint8List> _audioFrames = [];
  bool _isProcessing = false;
  double _audioOffsetSeconds = 0;

  /// Flush interval: decode buffered audio every 3 seconds.
  static const Duration _flushInterval = Duration(seconds: 3);

  /// Minimum bytes before we bother flushing (avoids decoding tiny scraps).
  /// ~0.5s of 16 kHz 16-bit mono = 16000 bytes.
  static const int _minBufferBytes = 16000;

  final String? _modelPath;

  LocalSttSocket(this._engine, {String? modelPath}) : _modelPath = modelPath;

  @override
  PureSocketStatus get status => _status;

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    if (_status == PureSocketStatus.connecting ||
        _status == PureSocketStatus.connected) {
      return false;
    }

    _status = PureSocketStatus.connecting;

    // Lazily initialize the engine if not yet done
    if (!_engine.isInitialized && _modelPath != null) {
      try {
        await _engine.initialize(_modelPath!);
      } catch (e) {
        debugPrint('[LocalSttSocket] Engine init failed: $e');
        _status = PureSocketStatus.notConnected;
        return false;
      }
    }

    if (!_engine.isInitialized) {
      debugPrint('[LocalSttSocket] Engine not initialized, cannot connect');
      _status = PureSocketStatus.notConnected;
      return false;
    }

    _status = PureSocketStatus.connected;
    _audioOffsetSeconds = 0;
    onConnected();
    _startFlushTimer();
    return true;
  }

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      _flushBuffer();
    });
  }

  int get _totalBufferBytes =>
      _audioFrames.fold<int>(0, (sum, frame) => sum + frame.length);

  void _flushBuffer() {
    if (_audioFrames.isEmpty || _status != PureSocketStatus.connected) return;
    if (_totalBufferBytes < _minBufferBytes || _isProcessing) return;

    _isProcessing = true;

    try {
      // Gather all buffered frames
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

      // Convert PCM16 (little-endian signed int16) to Float32 [-1.0, 1.0]
      final samples = _pcm16ToFloat32(pcm16);

      // Decode synchronously (native FFI pointers cannot cross isolate boundaries)
      final results = _engine.processAudio(samples);

      if (results.isNotEmpty) {
        _emitResults(results);
      } else {
        // Even with no speech, advance offset by the duration of audio processed
        final durationSeconds = samples.length / LocalSttEngine.sampleRate;
        _audioOffsetSeconds += durationSeconds;
      }
    } catch (e, trace) {
      debugPrint('[LocalSttSocket] Flush error: $e');
      onError(e, trace);
    } finally {
      _isProcessing = false;
    }
  }

  /// Convert decode results to the JSON segment format and emit via [onMessage].
  void _emitResults(List<LocalSttResult> results) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    var index = 0;

    final segmentsJson = results.map((r) {
      final segmentId =
          '${timestamp}_${(_audioOffsetSeconds + r.startTime).toStringAsFixed(2)}_$index';
      index++;
      return {
        'id': segmentId,
        'text': r.text,
        'speaker': 'SPEAKER_0',
        'speaker_id': 0,
        'is_user': true,
        'start': _audioOffsetSeconds + r.startTime,
        'end': _audioOffsetSeconds + r.endTime,
      };
    }).toList();

    // Advance offset to the end of the last segment
    _audioOffsetSeconds += results.last.endTime;

    if (segmentsJson.isNotEmpty) {
      onMessage(jsonEncode(segmentsJson));
    }
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

  @override
  void send(dynamic message) {
    if (message is Uint8List) {
      _audioFrames.add(message);
    } else if (message is List<int>) {
      _audioFrames.add(Uint8List.fromList(message));
    } else {
      debugPrint(
          '[LocalSttSocket] Unsupported message type: ${message.runtimeType}');
    }
  }

  @override
  Future disconnect() async {
    _flushTimer?.cancel();

    // Final flush to process remaining audio
    if (_audioFrames.isNotEmpty && !_isProcessing) {
      _flushBuffer();
    }

    _status = PureSocketStatus.disconnected;
    debugPrint('[LocalSttSocket] Disconnected');
    onClosed();
  }

  @override
  Future stop() async {
    await disconnect();
    _flushTimer?.cancel();
    _audioFrames.clear();
    _audioOffsetSeconds = 0;
  }

  @override
  void onMessage(dynamic message) {
    _listener?.onMessage(message);
  }

  @override
  void onConnected() {
    _listener?.onConnected();
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    _listener?.onClosed(closeCode);
  }

  @override
  void onError(Object err, StackTrace trace) {
    debugPrint('[LocalSttSocket] Error: $err');
    _listener?.onError(err, trace);
  }

  @override
  void onConnectionStateChanged(bool isConnected) {
    // No-op: local STT does not depend on network connectivity.
  }

  /// Flush remaining audio now, including VAD tail (used before finalizing).
  void flushNow() {
    if (_audioFrames.isEmpty && !_engine.isInitialized) return;
    if (_isProcessing) return;

    _isProcessing = true;

    try {
      // Process any remaining buffered frames
      if (_audioFrames.isNotEmpty) {
        final frames = List<Uint8List>.from(_audioFrames);
        _audioFrames.clear();

        final totalLength =
            frames.fold<int>(0, (sum, frame) => sum + frame.length);
        final pcm16 = Uint8List(totalLength);
        int offset = 0;
        for (final frame in frames) {
          pcm16.setRange(offset, offset + frame.length, frame);
          offset += frame.length;
        }

        final samples = _pcm16ToFloat32(pcm16);
        final results = _engine.processAudio(samples);
        if (results.isNotEmpty) {
          _emitResults(results);
        }
      }

      // Flush VAD tail to catch any speech at the end of the buffer
      final flushed = _engine.flush();
      if (flushed.isNotEmpty) {
        _emitResults(flushed);
      }
    } catch (e, trace) {
      debugPrint('[LocalSttSocket] FlushNow error: $e');
      onError(e, trace);
    } finally {
      _isProcessing = false;
    }
  }
}
