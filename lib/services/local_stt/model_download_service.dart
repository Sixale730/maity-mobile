import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/local_stt/model_manifest.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

enum DownloadState { idle, downloading, paused, validating, ready, error }

class DownloadProgress {
  final DownloadState state;
  final double progress; // 0.0 to 1.0
  final int bytesDownloaded;
  final int totalBytes;
  final double speedBytesPerSec;
  final String? errorMessage;
  final String? currentFile;
  final String? errorLog; // Detailed log for clipboard copy

  const DownloadProgress({
    this.state = DownloadState.idle,
    this.progress = 0.0,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.speedBytesPerSec = 0.0,
    this.errorMessage,
    this.currentFile,
    this.errorLog,
  });

  DownloadProgress copyWith({
    DownloadState? state,
    double? progress,
    int? bytesDownloaded,
    int? totalBytes,
    double? speedBytesPerSec,
    String? errorMessage,
    String? currentFile,
    String? errorLog,
  }) {
    return DownloadProgress(
      state: state ?? this.state,
      progress: progress ?? this.progress,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: totalBytes ?? this.totalBytes,
      speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
      errorMessage: errorMessage ?? this.errorMessage,
      currentFile: currentFile ?? this.currentFile,
      errorLog: errorLog ?? this.errorLog,
    );
  }
}

/// Manages downloading, validating, and deleting the Parakeet TDT model files.
///
/// Follows the singleton pattern from BackgroundUploadService.
/// Uses dio for HTTP downloads with progress and resume support.
/// Model files are stored in getApplicationSupportDirectory() (not purgeable on iOS).
class ModelDownloadService {
  ModelDownloadService._();
  static final ModelDownloadService _instance = ModelDownloadService._();
  static ModelDownloadService get instance => _instance;

  final ValueNotifier<DownloadProgress> downloadProgress =
      ValueNotifier(const DownloadProgress());

  late final Dio _dio;
  CancelToken? _cancelToken;
  String? _modelDirPath;
  bool _initialized = false;

  /// Whether all model files are present and pass size validation.
  bool get isModelReady =>
      downloadProgress.value.state == DownloadState.ready;

  /// Absolute path to the model directory, or null if not yet initialized.
  String? get modelPath => _modelDirPath;

  /// Initialize the service: resolve model directory and check existing files.
  Future<void> initialize() async {
    if (_initialized) return;

    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 30),
      followRedirects: true,
      maxRedirects: 5,
    ));

    final appSupport = await getApplicationSupportDirectory();
    _modelDirPath =
        '${appSupport.path}/${ParakeetModelManifest.modelDirName}';

    _initialized = true;

    // Check if model was previously downloaded and is still valid
    if (SharedPreferencesUtil().localSttModelDownloaded) {
      final valid = await _validateExistingFiles();
      if (valid) {
        downloadProgress.value =
            const DownloadProgress(state: DownloadState.ready, progress: 1.0);
        debugPrint('[ModelDownload] Model already downloaded and valid');
      } else {
        // Files missing or corrupted — reset preference
        SharedPreferencesUtil().localSttModelDownloaded = false;
        SharedPreferencesUtil().localSttModelPath = '';
        debugPrint(
            '[ModelDownload] Previously downloaded model is invalid, reset preference');
      }
    } else {
      // Also check on disk in case preference was lost
      final valid = await _validateExistingFiles();
      if (valid) {
        SharedPreferencesUtil().localSttModelDownloaded = true;
        SharedPreferencesUtil().localSttModelPath = _modelDirPath!;
        downloadProgress.value =
            const DownloadProgress(state: DownloadState.ready, progress: 1.0);
        debugPrint('[ModelDownload] Found valid model on disk, updated prefs');
      }
    }
  }

  /// Download all model files sequentially. Supports resume via Range headers.
  Future<bool> downloadModel() async {
    if (!_initialized) await initialize();
    if (isModelReady) return true;

    _cancelToken = CancelToken();

    // Ensure model directory exists
    final modelDir = Directory(_modelDirPath!);
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }

    const totalBytes = ParakeetModelManifest.totalExpectedBytes;
    int cumulativeBytes = 0;
    final stopwatch = Stopwatch()..start();

    downloadProgress.value = const DownloadProgress(
      state: DownloadState.downloading,
      totalBytes: ParakeetModelManifest.totalExpectedBytes,
    );

    for (final modelFile in ParakeetModelManifest.files) {
      if (_cancelToken?.isCancelled ?? false) {
        downloadProgress.value = const DownloadProgress(
          state: DownloadState.idle,
          errorMessage: 'Download cancelled',
        );
        return false;
      }

      final filePath = '$_modelDirPath/${modelFile.fileName}';
      final tmpPath = '$filePath.tmp';
      final file = File(filePath);

      // Skip if file already exists and passes validation
      if (await file.exists()) {
        final size = await file.length();
        if (modelFile.validateSize(size)) {
          cumulativeBytes += size;
          debugPrint(
              '[ModelDownload] ${modelFile.fileName} already valid, skipping');
          continue;
        }
      }

      downloadProgress.value = downloadProgress.value.copyWith(
        currentFile: modelFile.fileName,
      );

      try {
        // Check for partial .tmp file to resume
        final tmpFile = File(tmpPath);
        int resumeOffset = 0;
        if (await tmpFile.exists()) {
          resumeOffset = await tmpFile.length();
          debugPrint(
              '[ModelDownload] Resuming ${modelFile.fileName} from $resumeOffset bytes');
        }

        final int fileStartBytes = cumulativeBytes;

        await _dio.download(
          modelFile.url,
          tmpPath,
          cancelToken: _cancelToken,
          deleteOnError: false, // Keep partial file for resume
          options: resumeOffset > 0
              ? Options(headers: {'Range': 'bytes=$resumeOffset-'})
              : null,
          onReceiveProgress: (received, total) {
            final actualReceived = received + resumeOffset;
            final globalReceived = fileStartBytes + actualReceived;
            final elapsed = stopwatch.elapsedMilliseconds / 1000.0;
            final speed = elapsed > 0 ? globalReceived / elapsed : 0.0;

            downloadProgress.value = downloadProgress.value.copyWith(
              bytesDownloaded: globalReceived,
              progress: globalReceived / totalBytes,
              speedBytesPerSec: speed,
              currentFile: modelFile.fileName,
            );
          },
        );

        // Validate downloaded file size
        final downloadedFile = File(tmpPath);
        if (!await downloadedFile.exists()) {
          throw Exception('Downloaded file not found: $tmpPath');
        }

        final downloadedSize = await downloadedFile.length();
        if (!modelFile.validateSize(downloadedSize)) {
          await downloadedFile.delete();
          throw Exception(
              '${modelFile.fileName} size validation failed: $downloadedSize bytes '
              '(expected >= ${(modelFile.expectedBytes * modelFile.sizeThreshold).toInt()})');
        }

        // Atomic rename: .tmp -> final
        if (Platform.isWindows && await file.exists()) {
          await file.delete();
        }
        await downloadedFile.rename(filePath);
        cumulativeBytes += downloadedSize;

        debugPrint(
            '[ModelDownload] ${modelFile.fileName} downloaded ($downloadedSize bytes)');
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          downloadProgress.value = const DownloadProgress(
            state: DownloadState.idle,
            errorMessage: 'Download cancelled',
          );
          return false;
        }
        final status = e.response?.statusCode;
        final dioType = e.type.name;
        final bodyStr = e.response?.data?.toString();
        debugPrint(
            '[ModelDownload] DioError ${modelFile.fileName}: type=$dioType, '
            'status=$status, uri=${e.requestOptions.uri}, '
            'message=${e.message}, innerError=${e.error}');
        final log = await _buildErrorLog(
          fileName: modelFile.fileName,
          url: modelFile.url,
          bytesDownloaded: cumulativeBytes,
          errorMessage: e.message,
          dioErrorType: dioType,
          httpStatus: status,
          responseBody: bodyStr,
          redirects: e.response?.redirects,
          rawError: e.error?.toString(),
        );
        downloadProgress.value = DownloadProgress(
          state: DownloadState.error,
          errorMessage: '${modelFile.fileName}: ${_shortErrorMessage(e)}',
          bytesDownloaded: cumulativeBytes,
          totalBytes: totalBytes,
          currentFile: modelFile.fileName,
          errorLog: log,
        );
        return false;
      } catch (e, stackTrace) {
        debugPrint(
            '[ModelDownload] Error downloading ${modelFile.fileName}: $e\n$stackTrace');
        final log = await _buildErrorLog(
          fileName: modelFile.fileName,
          url: modelFile.url,
          bytesDownloaded: cumulativeBytes,
          errorMessage: e.toString(),
          rawError: '$e\n$stackTrace',
        );
        downloadProgress.value = DownloadProgress(
          state: DownloadState.error,
          errorMessage: 'Failed: ${modelFile.fileName} — $e',
          bytesDownloaded: cumulativeBytes,
          totalBytes: totalBytes,
          currentFile: modelFile.fileName,
          errorLog: log,
        );
        return false;
      }
    }

    stopwatch.stop();

    // Final validation pass
    downloadProgress.value = downloadProgress.value.copyWith(
      state: DownloadState.validating,
    );

    final valid = await _validateExistingFiles();
    if (valid) {
      SharedPreferencesUtil().localSttModelDownloaded = true;
      SharedPreferencesUtil().localSttModelPath = _modelDirPath!;
      downloadProgress.value = const DownloadProgress(
        state: DownloadState.ready,
        progress: 1.0,
      );
      debugPrint(
          '[ModelDownload] All files downloaded and validated in ${stopwatch.elapsed.inSeconds}s');
      return true;
    } else {
      final log = await _buildErrorLog(
        fileName: '(all files)',
        url: '(validation pass)',
        bytesDownloaded: cumulativeBytes,
        errorMessage: 'Final validation failed after download',
      );
      downloadProgress.value = DownloadProgress(
        state: DownloadState.error,
        errorMessage: 'Final validation failed after download',
        errorLog: log,
      );
      return false;
    }
  }

  /// Cancel an ongoing download.
  void cancelDownload() {
    _cancelToken?.cancel('User cancelled download');
    _cancelToken = null;
  }

  /// Delete all model files and reset preferences.
  Future<void> deleteModel() async {
    if (!_initialized) await initialize();

    cancelDownload();

    final modelDir = Directory(_modelDirPath!);
    if (await modelDir.exists()) {
      await modelDir.delete(recursive: true);
      debugPrint('[ModelDownload] Model directory deleted');
    }

    SharedPreferencesUtil().localSttModelDownloaded = false;
    SharedPreferencesUtil().localSttModelPath = '';

    downloadProgress.value = const DownloadProgress(state: DownloadState.idle);
  }

  /// Check if this iOS device has insufficient RAM for the model.
  Future<bool> isLowRamDevice() async {
    if (!Platform.isIOS) return false;
    final deviceInfo = DeviceInfoPlugin();
    final iosInfo = await deviceInfo.iosInfo;
    final model = iosInfo.utsname.machine;
    return ParakeetModelManifest.lowRamModels.contains(model);
  }

  /// Build a short, user-readable error message from a DioException.
  String _shortErrorMessage(DioException e) {
    final status = e.response?.statusCode;
    if (status != null) return 'HTTP $status (${e.type.name})';
    if (e.type == DioExceptionType.connectionTimeout) return 'Connection timeout';
    if (e.type == DioExceptionType.receiveTimeout) return 'Download timeout';
    if (e.type == DioExceptionType.connectionError) {
      return 'Connection error — check network';
    }
    return e.message ?? e.type.name;
  }

  /// Build a detailed error log string for clipboard copy.
  Future<String> _buildErrorLog({
    required String fileName,
    required String url,
    required int bytesDownloaded,
    String? errorMessage,
    String? dioErrorType,
    int? httpStatus,
    String? responseBody,
    List<RedirectRecord>? redirects,
    String? rawError,
  }) async {
    final buf = StringBuffer();
    try {
      buf.writeln('=== Maity Model Download Error ===');
      buf.writeln('Timestamp: ${DateTime.now().toUtc().toIso8601String()}');

      // App version
      try {
        final pkg = await PackageInfo.fromPlatform();
        buf.writeln('App: ${pkg.appName} ${pkg.version}+${pkg.buildNumber}');
      } catch (_) {
        buf.writeln('App: (could not read version)');
      }

      // Device info
      try {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isIOS) {
          final ios = await deviceInfo.iosInfo;
          buf.writeln('Device: ${ios.utsname.machine} (${ios.model})');
          buf.writeln('OS: iOS ${ios.systemVersion}');
        } else if (Platform.isAndroid) {
          final android = await deviceInfo.androidInfo;
          buf.writeln('Device: ${android.manufacturer} ${android.model}');
          buf.writeln('OS: Android ${android.version.release} (SDK ${android.version.sdkInt})');
        } else {
          buf.writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
        }
      } catch (_) {
        buf.writeln('Device: ${Platform.operatingSystem}');
      }

      // Download context
      buf.writeln('');
      buf.writeln('--- Download Context ---');
      buf.writeln('File: $fileName');
      buf.writeln('URL: $url');
      buf.writeln('Bytes downloaded: $bytesDownloaded');
      buf.writeln('Model dir: ${_modelDirPath ?? "(not set)"}');

      // Error details
      buf.writeln('');
      buf.writeln('--- Error Details ---');
      if (errorMessage != null) buf.writeln('Message: $errorMessage');
      if (dioErrorType != null) buf.writeln('Dio error type: $dioErrorType');
      if (httpStatus != null) buf.writeln('HTTP status: $httpStatus');
      if (redirects != null && redirects.isNotEmpty) {
        buf.writeln('Redirects: ${redirects.length}');
        for (final r in redirects) {
          buf.writeln('  ${r.statusCode} → ${r.location}');
        }
      }
      if (responseBody != null && responseBody.isNotEmpty) {
        final truncated = responseBody.length > 500
            ? '${responseBody.substring(0, 500)}...(truncated)'
            : responseBody;
        buf.writeln('Response body: $truncated');
      }
      if (rawError != null) {
        buf.writeln('Raw error: $rawError');
      }
    } catch (e) {
      buf.writeln('(error building log: $e)');
    }
    return buf.toString();
  }

  /// Validate that all model files exist and meet minimum size thresholds.
  Future<bool> _validateExistingFiles() async {
    if (_modelDirPath == null) return false;

    final modelDir = Directory(_modelDirPath!);
    if (!await modelDir.exists()) return false;

    for (final modelFile in ParakeetModelManifest.files) {
      final file = File('$_modelDirPath/${modelFile.fileName}');
      if (!await file.exists()) {
        debugPrint(
            '[ModelDownload] Validation failed: ${modelFile.fileName} not found');
        return false;
      }
      final size = await file.length();
      if (!modelFile.validateSize(size)) {
        debugPrint(
            '[ModelDownload] Validation failed: ${modelFile.fileName} size $size < threshold');
        return false;
      }
    }
    return true;
  }

  void dispose() {
    cancelDownload();
    downloadProgress.dispose();
    _dio.close();
  }
}
