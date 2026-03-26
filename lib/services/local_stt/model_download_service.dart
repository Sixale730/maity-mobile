import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/model_manifest.dart';
import 'package:omi/services/local_stt/moonshine_model_manifest.dart';
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

/// Manages downloading, validating, and deleting local STT model files.
///
/// Supports multiple models (Parakeet, Moonshine) with per-model progress tracking.
/// Model files are stored in getApplicationSupportDirectory() (not purgeable on iOS).
class ModelDownloadService {
  ModelDownloadService._();
  static final ModelDownloadService _instance = ModelDownloadService._();
  static ModelDownloadService get instance => _instance;

  // --- Per-model progress notifiers ---
  final Map<LocalSttModelType, ValueNotifier<DownloadProgress>> _progressMap = {
    LocalSttModelType.parakeet:
        ValueNotifier(const DownloadProgress()),
    LocalSttModelType.moonshine:
        ValueNotifier(const DownloadProgress()),
  };

  /// Backward-compatible: progress for Parakeet (default/legacy).
  ValueNotifier<DownloadProgress> get downloadProgress =>
      _progressMap[LocalSttModelType.parakeet]!;

  /// Get progress notifier for a specific model type.
  ValueNotifier<DownloadProgress> progressFor(LocalSttModelType type) =>
      _progressMap[type]!;

  late final Dio _dio;
  CancelToken? _cancelToken;
  final Map<LocalSttModelType, String> _modelDirPaths = {};
  String? _appSupportPath;
  bool _initialized = false;

  // --- Manifest registry ---
  static final Map<LocalSttModelType, LocalSttModelManifest> _manifests = {
    LocalSttModelType.parakeet: ParakeetModelManifest(),
    LocalSttModelType.moonshine: MoonshineModelManifest(),
  };

  LocalSttModelManifest manifestFor(LocalSttModelType type) => _manifests[type]!;

  /// Whether the given model's files are present and pass validation.
  bool isModelReadyFor(LocalSttModelType type) =>
      _progressMap[type]!.value.state == DownloadState.ready;

  /// Backward-compatible: whether the Parakeet model is ready.
  bool get isModelReady => isModelReadyFor(LocalSttModelType.parakeet);

  /// Whether ANY local STT model is ready (for offline fallback logic).
  bool get isAnyModelReady => LocalSttModelType.values.any(isModelReadyFor);

  /// Model path for a specific type, or null if not initialized.
  String? modelPathFor(LocalSttModelType type) => _modelDirPaths[type];

  /// Backward-compatible: path for Parakeet model.
  String? get modelPath => modelPathFor(LocalSttModelType.parakeet);

  /// Initialize the service: resolve model directories and check existing files.
  Future<void> initialize() async {
    if (_initialized) return;

    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 30),
      followRedirects: true,
      maxRedirects: 5,
    ));

    final appSupport = await getApplicationSupportDirectory();
    _appSupportPath = appSupport.path;

    for (final type in LocalSttModelType.values) {
      final manifest = manifestFor(type);
      _modelDirPaths[type] = '${appSupport.path}/${manifest.modelDirName}';
    }

    _initialized = true;

    // Check existing models
    await _checkExistingModel(LocalSttModelType.parakeet);
    await _checkExistingModel(LocalSttModelType.moonshine);
  }

  Future<void> _checkExistingModel(LocalSttModelType type) async {
    final prefs = SharedPreferencesUtil();
    final isDownloaded = type == LocalSttModelType.parakeet
        ? prefs.localSttModelDownloaded
        : prefs.localSttMoonshineDownloaded;
    final path = _modelDirPaths[type]!;

    if (isDownloaded) {
      final valid = await _validateExistingFiles(type);
      if (valid) {
        _progressMap[type]!.value =
            const DownloadProgress(state: DownloadState.ready, progress: 1.0);
        debugPrint('[ModelDownload] ${type.name} already downloaded and valid');
      } else {
        _setPrefs(type, downloaded: false, path: '');
        debugPrint(
            '[ModelDownload] ${type.name} invalid, reset preference');
      }
    } else {
      final valid = await _validateExistingFiles(type);
      if (valid) {
        _setPrefs(type, downloaded: true, path: path);
        _progressMap[type]!.value =
            const DownloadProgress(state: DownloadState.ready, progress: 1.0);
        debugPrint('[ModelDownload] Found valid ${type.name} on disk');
      }
    }
  }

  /// Download model files for [type]. Returns true on success.
  Future<bool> downloadModel([
    LocalSttModelType type = LocalSttModelType.parakeet,
  ]) async {
    if (!_initialized) await initialize();
    if (isModelReadyFor(type)) return true;

    final manifest = manifestFor(type);
    final progress = _progressMap[type]!;

    _cancelToken = CancelToken();

    // Ensure model directory exists
    final modelDirPath = _modelDirPaths[type]!;
    final modelDir = Directory(modelDirPath);
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }

    if (manifest.isArchiveDownload) {
      return _downloadArchiveModel(type, manifest, modelDirPath, progress);
    } else {
      return _downloadIndividualFiles(type, manifest, modelDirPath, progress);
    }
  }

  /// Download model distributed as a tar.bz2 archive (Moonshine).
  Future<bool> _downloadArchiveModel(
    LocalSttModelType type,
    LocalSttModelManifest manifest,
    String modelDirPath,
    ValueNotifier<DownloadProgress> progress,
  ) async {
    final stopwatch = Stopwatch()..start();
    final archivePath = '$_appSupportPath/${manifest.modelName}.tar.bz2';
    final totalBytes = manifest.archiveBytes;

    progress.value = DownloadProgress(
      state: DownloadState.downloading,
      totalBytes: totalBytes,
      currentFile: '${manifest.modelName}.tar.bz2',
    );

    try {
      // Download the archive
      await _dio.download(
        manifest.archiveUrl,
        archivePath,
        cancelToken: _cancelToken,
        deleteOnError: false,
        onReceiveProgress: (received, total) {
          final elapsed = stopwatch.elapsedMilliseconds / 1000.0;
          final speed = elapsed > 0 ? received / elapsed : 0.0;
          progress.value = progress.value.copyWith(
            bytesDownloaded: received,
            progress: totalBytes > 0 ? received / totalBytes : 0.0,
            speedBytesPerSec: speed,
          );
        },
      );

      // Extract the archive
      progress.value = progress.value.copyWith(
        state: DownloadState.validating,
        currentFile: 'Extracting...',
      );

      await _extractTarBz2(archivePath, modelDirPath, manifest.archiveInnerDir);

      // Download Silero VAD separately if needed
      final vadFile = manifest.files.where((f) => f.fileName == 'silero_vad.onnx').firstOrNull;
      if (vadFile != null && vadFile.url.isNotEmpty) {
        final vadPath = '$modelDirPath/silero_vad.onnx';
        if (!await File(vadPath).exists()) {
          // Try to copy from Parakeet directory first
          final parakeetVad = '${_modelDirPaths[LocalSttModelType.parakeet]}/silero_vad.onnx';
          if (await File(parakeetVad).exists()) {
            await File(parakeetVad).copy(vadPath);
            debugPrint('[ModelDownload] Copied silero_vad.onnx from Parakeet');
          } else {
            progress.value = progress.value.copyWith(
              currentFile: 'silero_vad.onnx',
            );
            await _dio.download(vadFile.url, vadPath, cancelToken: _cancelToken);
            debugPrint('[ModelDownload] Downloaded silero_vad.onnx');
          }
        }
      }

      // Clean up archive file
      try {
        await File(archivePath).delete();
      } catch (_) {}

      stopwatch.stop();

      // Final validation
      final valid = await _validateExistingFiles(type);
      if (valid) {
        _setPrefs(type, downloaded: true, path: modelDirPath);
        progress.value = const DownloadProgress(
          state: DownloadState.ready,
          progress: 1.0,
        );
        debugPrint(
            '[ModelDownload] ${type.name} extracted and validated in ${stopwatch.elapsed.inSeconds}s');
        return true;
      } else {
        final log = await _buildErrorLog(
          fileName: '(validation)',
          url: manifest.archiveUrl,
          bytesDownloaded: totalBytes,
          errorMessage: 'Validation failed after extraction',
        );
        progress.value = DownloadProgress(
          state: DownloadState.error,
          errorMessage: 'Validation failed after extraction',
          errorLog: log,
        );
        return false;
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        progress.value = const DownloadProgress(
          state: DownloadState.idle,
          errorMessage: 'Download cancelled',
        );
        return false;
      }
      final log = await _buildErrorLog(
        fileName: '${manifest.modelName}.tar.bz2',
        url: manifest.archiveUrl,
        bytesDownloaded: progress.value.bytesDownloaded,
        errorMessage: e.message,
        dioErrorType: e.type.name,
        httpStatus: e.response?.statusCode,
      );
      progress.value = DownloadProgress(
        state: DownloadState.error,
        errorMessage: _shortErrorMessage(e),
        errorLog: log,
      );
      return false;
    } catch (e, stackTrace) {
      debugPrint('[ModelDownload] Archive download error: $e\n$stackTrace');
      final log = await _buildErrorLog(
        fileName: '${manifest.modelName}.tar.bz2',
        url: manifest.archiveUrl,
        bytesDownloaded: progress.value.bytesDownloaded,
        errorMessage: e.toString(),
        rawError: '$e\n$stackTrace',
      );
      progress.value = DownloadProgress(
        state: DownloadState.error,
        errorMessage: 'Failed: $e',
        errorLog: log,
      );
      return false;
    }
  }

  /// Extract a tar.bz2 archive, moving files from [archiveInnerDir] to [targetDir].
  Future<void> _extractTarBz2(
    String archivePath,
    String targetDir,
    String archiveInnerDir,
  ) async {
    final archiveBytes = await File(archivePath).readAsBytes();

    // Decompress bzip2
    final decompressed = BZip2Decoder().decodeBytes(archiveBytes);

    // Decode tar
    final archive = TarDecoder().decodeBytes(decompressed);

    final targetDirectory = Directory(targetDir);
    if (!await targetDirectory.exists()) {
      await targetDirectory.create(recursive: true);
    }

    for (final file in archive) {
      if (file.isFile) {
        // Files inside tar are usually like: archiveInnerDir/filename.onnx
        // We want to flatten them to targetDir/filename.onnx
        String fileName = file.name;
        if (fileName.contains('/')) {
          fileName = fileName.split('/').last;
        }
        // Skip hidden/metadata files
        if (fileName.startsWith('.') || fileName.isEmpty) continue;

        final outFile = File('$targetDir/$fileName');
        await outFile.writeAsBytes(file.content as List<int>);
        debugPrint('[ModelDownload] Extracted: $fileName (${file.size} bytes)');
      }
    }
  }

  /// Download model distributed as individual files (Parakeet).
  Future<bool> _downloadIndividualFiles(
    LocalSttModelType type,
    LocalSttModelManifest manifest,
    String modelDirPath,
    ValueNotifier<DownloadProgress> progress,
  ) async {
    final totalBytes = manifest.totalExpectedBytes;
    int cumulativeBytes = 0;
    final stopwatch = Stopwatch()..start();

    progress.value = DownloadProgress(
      state: DownloadState.downloading,
      totalBytes: totalBytes,
    );

    for (final modelFile in manifest.files) {
      if (_cancelToken?.isCancelled ?? false) {
        progress.value = const DownloadProgress(
          state: DownloadState.idle,
          errorMessage: 'Download cancelled',
        );
        return false;
      }

      final filePath = '$modelDirPath/${modelFile.fileName}';
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

      progress.value = progress.value.copyWith(
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

            progress.value = progress.value.copyWith(
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
          progress.value = const DownloadProgress(
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
        progress.value = DownloadProgress(
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
        progress.value = DownloadProgress(
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
    progress.value = progress.value.copyWith(
      state: DownloadState.validating,
    );

    final valid = await _validateExistingFiles(type);
    if (valid) {
      _setPrefs(type, downloaded: true, path: modelDirPath);
      progress.value = const DownloadProgress(
        state: DownloadState.ready,
        progress: 1.0,
      );
      debugPrint(
          '[ModelDownload] ${type.name} downloaded and validated in ${stopwatch.elapsed.inSeconds}s');
      return true;
    } else {
      final log = await _buildErrorLog(
        fileName: '(all files)',
        url: '(validation pass)',
        bytesDownloaded: cumulativeBytes,
        errorMessage: 'Final validation failed after download',
      );
      progress.value = DownloadProgress(
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

  /// Delete model files for [type] and reset preferences.
  Future<void> deleteModel([
    LocalSttModelType type = LocalSttModelType.parakeet,
  ]) async {
    if (!_initialized) await initialize();

    cancelDownload();

    final modelDirPath = _modelDirPaths[type];
    if (modelDirPath != null) {
      final modelDir = Directory(modelDirPath);
      if (await modelDir.exists()) {
        await modelDir.delete(recursive: true);
        debugPrint('[ModelDownload] ${type.name} directory deleted');
      }
    }

    _setPrefs(type, downloaded: false, path: '');
    _progressMap[type]!.value =
        const DownloadProgress(state: DownloadState.idle);
  }

  /// Check if this iOS device has insufficient RAM for the model.
  Future<bool> isLowRamDevice() async {
    if (!Platform.isIOS) return false;
    final deviceInfo = DeviceInfoPlugin();
    final iosInfo = await deviceInfo.iosInfo;
    final model = iosInfo.utsname.machine;
    return ParakeetModelManifest.lowRamModels.contains(model);
  }

  // --- Preferences helpers ---

  void _setPrefs(LocalSttModelType type,
      {required bool downloaded, required String path}) {
    final prefs = SharedPreferencesUtil();
    if (type == LocalSttModelType.parakeet) {
      prefs.localSttModelDownloaded = downloaded;
      prefs.localSttModelPath = path;
    } else if (type == LocalSttModelType.moonshine) {
      prefs.localSttMoonshineDownloaded = downloaded;
      prefs.localSttMoonshinePath = path;
    }
  }

  // --- Error helpers ---

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

      try {
        final pkg = await PackageInfo.fromPlatform();
        buf.writeln('App: ${pkg.appName} ${pkg.version}+${pkg.buildNumber}');
      } catch (_) {
        buf.writeln('App: (could not read version)');
      }

      try {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isIOS) {
          final ios = await deviceInfo.iosInfo;
          buf.writeln('Device: ${ios.utsname.machine} (${ios.model})');
          buf.writeln('OS: iOS ${ios.systemVersion}');
        } else if (Platform.isAndroid) {
          final android = await deviceInfo.androidInfo;
          buf.writeln('Device: ${android.manufacturer} ${android.model}');
          buf.writeln(
              'OS: Android ${android.version.release} (SDK ${android.version.sdkInt})');
        } else {
          buf.writeln(
              'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
        }
      } catch (_) {
        buf.writeln('Device: ${Platform.operatingSystem}');
      }

      buf.writeln('');
      buf.writeln('--- Download Context ---');
      buf.writeln('File: $fileName');
      buf.writeln('URL: $url');
      buf.writeln('Bytes downloaded: $bytesDownloaded');

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
  Future<bool> _validateExistingFiles([
    LocalSttModelType type = LocalSttModelType.parakeet,
  ]) async {
    final modelDirPath = _modelDirPaths[type];
    if (modelDirPath == null) return false;

    final modelDir = Directory(modelDirPath);
    if (!await modelDir.exists()) return false;

    final manifest = manifestFor(type);
    for (final modelFile in manifest.files) {
      final file = File('$modelDirPath/${modelFile.fileName}');
      if (!await file.exists()) {
        debugPrint(
            '[ModelDownload] Validation failed: ${modelFile.fileName} not found in ${type.name}');
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
    for (final notifier in _progressMap.values) {
      notifier.dispose();
    }
    _dio.close();
  }
}
