import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/local_stt/model_download_service.dart';
import 'package:omi/services/local_stt/speaker_model_manifest.dart';
import 'package:path_provider/path_provider.dart';

/// Manages downloading the speaker embedding model (~28 MB) for on-device
/// speaker identification. Follows the same singleton + dio pattern as
/// [ModelDownloadService] but simplified for a single file.
class SpeakerModelDownloadService {
  SpeakerModelDownloadService._();
  static final SpeakerModelDownloadService _instance =
      SpeakerModelDownloadService._();
  static SpeakerModelDownloadService get instance => _instance;

  final ValueNotifier<DownloadProgress> downloadProgress =
      ValueNotifier(const DownloadProgress());

  late final Dio _dio;
  CancelToken? _cancelToken;
  String? _modelDirPath;
  bool _initialized = false;

  bool get isModelReady =>
      downloadProgress.value.state == DownloadState.ready;

  /// Full path to the .onnx model file, or null if not ready.
  String? get modelFilePath => _modelDirPath != null
      ? '$_modelDirPath/${SpeakerModelManifest.modelFileName}'
      : null;

  /// Full path to the model directory.
  String? get modelDirPath => _modelDirPath;

  Future<void> initialize() async {
    if (_initialized) return;

    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      followRedirects: true,
      maxRedirects: 5,
    ));

    final appSupport = await getApplicationSupportDirectory();
    _modelDirPath =
        '${appSupport.path}/${SpeakerModelManifest.modelDirName}';

    _initialized = true;

    if (SharedPreferencesUtil().speakerModelDownloaded) {
      final valid = await _validateModelFile();
      if (valid) {
        downloadProgress.value =
            const DownloadProgress(state: DownloadState.ready, progress: 1.0);
        debugPrint('[SpeakerModelDownload] Model already downloaded and valid');
      } else {
        SharedPreferencesUtil().speakerModelDownloaded = false;
        SharedPreferencesUtil().speakerModelPath = '';
        debugPrint(
            '[SpeakerModelDownload] Previously downloaded model invalid, reset');
      }
    } else {
      final valid = await _validateModelFile();
      if (valid) {
        SharedPreferencesUtil().speakerModelDownloaded = true;
        SharedPreferencesUtil().speakerModelPath = modelFilePath!;
        downloadProgress.value =
            const DownloadProgress(state: DownloadState.ready, progress: 1.0);
        debugPrint(
            '[SpeakerModelDownload] Found valid model on disk, updated prefs');
      }
    }
  }

  Future<bool> downloadModel() async {
    if (!_initialized) await initialize();
    if (isModelReady) return true;

    _cancelToken = CancelToken();

    final modelDir = Directory(_modelDirPath!);
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }

    final filePath = modelFilePath!;
    final tmpPath = '$filePath.tmp';
    final file = File(filePath);

    // Skip if already valid
    if (await file.exists()) {
      final size = await file.length();
      if (SpeakerModelManifest.validateModelSize(size)) {
        _markReady();
        return true;
      }
    }

    downloadProgress.value = const DownloadProgress(
      state: DownloadState.downloading,
      totalBytes: SpeakerModelManifest.expectedBytes,
      currentFile: SpeakerModelManifest.modelFileName,
    );

    final stopwatch = Stopwatch()..start();

    try {
      // Check for partial .tmp file to resume
      final tmpFile = File(tmpPath);
      int resumeOffset = 0;
      if (await tmpFile.exists()) {
        resumeOffset = await tmpFile.length();
        debugPrint(
            '[SpeakerModelDownload] Resuming from $resumeOffset bytes');
      }

      await _dio.download(
        SpeakerModelManifest.url,
        tmpPath,
        cancelToken: _cancelToken,
        deleteOnError: false,
        options: resumeOffset > 0
            ? Options(headers: {'Range': 'bytes=$resumeOffset-'})
            : null,
        onReceiveProgress: (received, total) {
          final actual = received + resumeOffset;
          final elapsed = stopwatch.elapsedMilliseconds / 1000.0;
          final speed = elapsed > 0 ? actual / elapsed : 0.0;

          downloadProgress.value = downloadProgress.value.copyWith(
            bytesDownloaded: actual,
            progress: actual / SpeakerModelManifest.expectedBytes,
            speedBytesPerSec: speed,
          );
        },
      );

      // Validate
      final downloadedFile = File(tmpPath);
      if (!await downloadedFile.exists()) {
        throw Exception('Downloaded file not found: $tmpPath');
      }

      final downloadedSize = await downloadedFile.length();
      if (!SpeakerModelManifest.validateModelSize(downloadedSize)) {
        await downloadedFile.delete();
        throw Exception(
            'Size validation failed: $downloadedSize bytes '
            '(expected >= ${(SpeakerModelManifest.expectedBytes * SpeakerModelManifest.sizeThreshold).toInt()})');
      }

      // Atomic rename
      if (Platform.isWindows && await file.exists()) {
        await file.delete();
      }
      await downloadedFile.rename(filePath);

      stopwatch.stop();
      _markReady();
      debugPrint(
          '[SpeakerModelDownload] Downloaded in ${stopwatch.elapsed.inSeconds}s');
      return true;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        downloadProgress.value = const DownloadProgress(
          state: DownloadState.idle,
          errorMessage: 'Download cancelled',
        );
        return false;
      }
      debugPrint('[SpeakerModelDownload] DioError: ${e.type.name} ${e.message}');
      downloadProgress.value = DownloadProgress(
        state: DownloadState.error,
        errorMessage: _shortErrorMessage(e),
      );
      return false;
    } catch (e) {
      debugPrint('[SpeakerModelDownload] Error: $e');
      downloadProgress.value = DownloadProgress(
        state: DownloadState.error,
        errorMessage: 'Failed: $e',
      );
      return false;
    }
  }

  void cancelDownload() {
    _cancelToken?.cancel('User cancelled');
    _cancelToken = null;
  }

  Future<void> deleteModel() async {
    if (!_initialized) await initialize();

    cancelDownload();

    final modelDir = Directory(_modelDirPath!);
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
      debugPrint('[SpeakerModelDownload] Model directory deleted');
    }

    SharedPreferencesUtil().speakerModelDownloaded = false;
    SharedPreferencesUtil().speakerModelPath = '';
    SharedPreferencesUtil().localSpeakerEmbeddingPath = '';

    downloadProgress.value = const DownloadProgress(state: DownloadState.idle);
  }

  void _markReady() {
    SharedPreferencesUtil().speakerModelDownloaded = true;
    SharedPreferencesUtil().speakerModelPath = modelFilePath!;
    downloadProgress.value = const DownloadProgress(
      state: DownloadState.ready,
      progress: 1.0,
    );
  }

  Future<bool> _validateModelFile() async {
    if (_modelDirPath == null) return false;

    final file = File(modelFilePath!);
    if (!await file.exists()) return false;

    final size = await file.length();
    return SpeakerModelManifest.validateModelSize(size);
  }

  String _shortErrorMessage(DioException e) {
    final status = e.response?.statusCode;
    if (status != null) return 'HTTP $status';
    if (e.type == DioExceptionType.connectionTimeout) return 'Connection timeout';
    if (e.type == DioExceptionType.receiveTimeout) return 'Download timeout';
    if (e.type == DioExceptionType.connectionError) {
      return 'Connection error — check network';
    }
    return e.message ?? e.type.name;
  }

  void dispose() {
    cancelDownload();
    downloadProgress.dispose();
    _dio.close();
  }
}
