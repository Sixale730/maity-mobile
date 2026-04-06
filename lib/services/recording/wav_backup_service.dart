import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Concurrent WAV backup writer for recording sessions.
///
/// Writes PCM16 audio to a WAV file in parallel with the STT pipeline.
/// The WAV header is periodically refreshed so the file is playable
/// even if the app crashes mid-recording.
///
/// Lifecycle: [start] → [writeAudio] (repeated) → [stop] or [dispose].
class WavBackupService {
  RandomAccessFile? _raf;
  int _dataBytes = 0;
  int _writeCount = 0;
  String? _filePath;
  bool _disposed = false;

  static const int _headerSize = 44;
  static const int _sampleRate = 16000;
  static const int _bitsPerSample = 16;
  static const int _numChannels = 1;
  static const int _byteRate = _sampleRate * _numChannels * (_bitsPerSample ~/ 8);
  static const int _blockAlign = _numChannels * (_bitsPerSample ~/ 8);

  /// Refresh WAV header every 500 writes (~30s at 100fps phone mic)
  /// so the file is playable even after a crash.
  static const int _headerRefreshInterval = 500;

  /// Directory name under app support for WAV backups.
  static const String wavDirName = 'wav_recordings';

  /// Current file path, or null if not started.
  String? get filePath => _filePath;

  /// Whether the service is actively recording.
  bool get isRecording => !_disposed && _raf != null;

  /// Total bytes of PCM data written so far.
  int get dataBytes => _dataBytes;

  /// Start a new WAV backup for the given session.
  ///
  /// Creates the file at `{appSupport}/wav_recordings/{sessionId}.wav`
  /// with a placeholder header that will be updated on [stop] or periodically.
  Future<String> start(String sessionId) async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory('${appSupport.path}/$wavDirName');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    _filePath = '${dir.path}/$sessionId.wav';
    _raf = await File(_filePath!).open(mode: FileMode.write);
    _dataBytes = 0;
    _writeCount = 0;
    _disposed = false;

    // Write placeholder header (dataSize=0, updated on stop/refresh)
    _raf!.writeFromSync(_buildWavHeader(0));

    debugPrint('[WavBackup] Started: $_filePath');
    return _filePath!;
  }

  /// Append PCM16 audio bytes to the WAV file.
  ///
  /// This is called from [TranscriptionPipeline.sendToSocket] on every
  /// audio frame. Must be fast — no async, no allocation.
  void writeAudio(Uint8List pcm16Bytes) {
    if (_disposed || _raf == null || pcm16Bytes.isEmpty) return;

    try {
      _raf!.writeFromSync(pcm16Bytes);
      _dataBytes += pcm16Bytes.length;
      _writeCount++;

      // Periodically refresh header so file is playable after crash
      if (_writeCount >= _headerRefreshInterval) {
        _refreshHeader();
        _writeCount = 0;
      }
    } catch (e) {
      debugPrint('[WavBackup] Write error: $e');
    }
  }

  /// Finalize: update header with correct data size and close.
  ///
  /// Returns the file path, or null if not recording.
  Future<String?> stop() async {
    if (_disposed || _raf == null) return null;

    try {
      _refreshHeader();
      await _raf!.close();
      debugPrint('[WavBackup] Stopped: $_filePath '
          '(${(_dataBytes / 1024 / 1024).toStringAsFixed(1)} MB, '
          '${(_dataBytes / _byteRate).toStringAsFixed(0)}s audio)');
    } catch (e) {
      debugPrint('[WavBackup] Stop error: $e');
    }

    _raf = null;
    _disposed = true;
    return _filePath;
  }

  /// Dispose without finalizing (e.g., on error or discard).
  void dispose() {
    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    _disposed = true;
  }

  /// Rewrite the 44-byte WAV header with the current data size.
  ///
  /// Seeks to position 0, writes the header, then seeks back.
  /// This makes the file playable up to the last refresh point.
  void _refreshHeader() {
    if (_raf == null) return;
    try {
      final currentPos = _raf!.positionSync();
      _raf!.setPositionSync(0);
      _raf!.writeFromSync(_buildWavHeader(_dataBytes));
      _raf!.setPositionSync(currentPos);
    } catch (e) {
      debugPrint('[WavBackup] Header refresh error: $e');
    }
  }

  /// Build a standard 44-byte WAV header for PCM16 mono 16kHz audio.
  Uint8List _buildWavHeader(int dataSize) {
    final header = ByteData(_headerSize);
    final fileSize = _headerSize + dataSize - 8;

    // RIFF header
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, fileSize, Endian.little);
    header.setUint8(8, 0x57); // 'W'
    header.setUint8(9, 0x41); // 'A'
    header.setUint8(10, 0x56); // 'V'
    header.setUint8(11, 0x45); // 'E'

    // fmt sub-chunk
    header.setUint8(12, 0x66); // 'f'
    header.setUint8(13, 0x6D); // 'm'
    header.setUint8(14, 0x74); // 't'
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little); // Sub-chunk size (PCM = 16)
    header.setUint16(20, 1, Endian.little); // Audio format (PCM = 1)
    header.setUint16(22, _numChannels, Endian.little);
    header.setUint32(24, _sampleRate, Endian.little);
    header.setUint32(28, _byteRate, Endian.little);
    header.setUint16(32, _blockAlign, Endian.little);
    header.setUint16(34, _bitsPerSample, Endian.little);

    // data sub-chunk
    header.setUint8(36, 0x64); // 'd'
    header.setUint8(37, 0x61); // 'a'
    header.setUint8(38, 0x74); // 't'
    header.setUint8(39, 0x61); // 'a'
    header.setUint32(40, dataSize, Endian.little);

    return header.buffer.asUint8List();
  }
}
