import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/model_download_service.dart';
import 'package:omi/services/local_stt/speaker_model_download_service.dart';

class LocalSttProvider extends ChangeNotifier {
  // --- Per-model download state (Parakeet = legacy default) ---
  DownloadState _downloadState = DownloadState.idle;
  double _downloadProgress = 0.0;
  int _bytesDownloaded = 0;
  int _totalBytes = 0;
  double _speedBytesPerSec = 0.0;
  String? _errorMessage;
  String? _errorLog;
  String? _currentFile;
  bool _deviceRamWarning = false;

  // Moonshine download state
  DownloadState _moonshineDownloadState = DownloadState.idle;
  double _moonshineDownloadProgress = 0.0;
  int _moonshineBytesDownloaded = 0;
  int _moonshineTotalBytes = 0;
  double _moonshineSpeedBytesPerSec = 0.0;
  String? _moonshineErrorMessage;
  String? _moonshineErrorLog;
  String? _moonshineCurrentFile;

  // Speaker model state
  DownloadState _speakerDownloadState = DownloadState.idle;
  double _speakerDownloadProgress = 0.0;

  // --- Parakeet getters (backward-compatible) ---
  DownloadState get downloadState => _downloadState;
  double get downloadProgress => _downloadProgress;
  int get bytesDownloaded => _bytesDownloaded;
  int get totalBytes => _totalBytes;
  double get speedBytesPerSec => _speedBytesPerSec;
  String? get errorMessage => _errorMessage;
  String? get errorLog => _errorLog;
  String? get currentFile => _currentFile;
  bool get deviceRamWarning => _deviceRamWarning;
  bool get isModelReady => _downloadState == DownloadState.ready;
  bool get isDownloading => _downloadState == DownloadState.downloading;

  // --- Moonshine getters ---
  DownloadState get moonshineDownloadState => _moonshineDownloadState;
  double get moonshineDownloadProgress => _moonshineDownloadProgress;
  int get moonshineBytesDownloaded => _moonshineBytesDownloaded;
  int get moonshineTotalBytes => _moonshineTotalBytes;
  double get moonshineSpeedBytesPerSec => _moonshineSpeedBytesPerSec;
  String? get moonshineErrorMessage => _moonshineErrorMessage;
  String? get moonshineErrorLog => _moonshineErrorLog;
  String? get moonshineCurrentFile => _moonshineCurrentFile;
  bool get isMoonshineReady => _moonshineDownloadState == DownloadState.ready;
  bool get isMoonshineDownloading =>
      _moonshineDownloadState == DownloadState.downloading;

  // --- Generic per-type getters ---
  DownloadState stateFor(LocalSttModelType type) =>
      type == LocalSttModelType.moonshine
          ? _moonshineDownloadState
          : _downloadState;

  bool isReadyFor(LocalSttModelType type) =>
      stateFor(type) == DownloadState.ready;

  bool isDownloadingFor(LocalSttModelType type) =>
      stateFor(type) == DownloadState.downloading;

  // --- Model selection ---
  LocalSttModelType get selectedModel => LocalSttModelType.fromString(
      SharedPreferencesUtil().activeLocalSttModel);

  void selectModel(LocalSttModelType type) {
    SharedPreferencesUtil().activeLocalSttModel = type.name;
    notifyListeners();
  }

  // --- Shared settings ---
  bool get autoFallbackEnabled => SharedPreferencesUtil().localSttAutoFallback;

  // --- Speaker model getters ---
  DownloadState get speakerDownloadState => _speakerDownloadState;
  double get speakerDownloadProgress => _speakerDownloadProgress;
  bool get isSpeakerModelReady => _speakerDownloadState == DownloadState.ready;
  bool get isSpeakerModelDownloading =>
      _speakerDownloadState == DownloadState.downloading;
  bool get hasLocalSpeakerEmbedding =>
      SharedPreferencesUtil().localSpeakerEmbeddingPath.isNotEmpty;

  LocalSttProvider() {
    _init();
  }

  void _init() {
    // Listen to Parakeet progress
    ModelDownloadService.instance
        .progressFor(LocalSttModelType.parakeet)
        .addListener(_onParakeetProgressChanged);

    // Listen to Moonshine progress
    ModelDownloadService.instance
        .progressFor(LocalSttModelType.moonshine)
        .addListener(_onMoonshineProgressChanged);

    // Listen to SpeakerModelDownloadService progress
    SpeakerModelDownloadService.instance.downloadProgress
        .addListener(_onSpeakerProgressChanged);

    // Sync initial state
    _syncParakeetState();
    _syncMoonshineState();

    final speakerCurrent =
        SpeakerModelDownloadService.instance.downloadProgress.value;
    _speakerDownloadState = speakerCurrent.state;
    _speakerDownloadProgress = speakerCurrent.progress;

    _checkDeviceRam();
  }

  void _syncParakeetState() {
    final current = ModelDownloadService.instance
        .progressFor(LocalSttModelType.parakeet)
        .value;
    _downloadState = current.state;
    _downloadProgress = current.progress;
    _bytesDownloaded = current.bytesDownloaded;
    _totalBytes = current.totalBytes;
    _speedBytesPerSec = current.speedBytesPerSec;
    _errorMessage = current.errorMessage;
    _errorLog = current.errorLog;
    _currentFile = current.currentFile;
  }

  void _syncMoonshineState() {
    final current = ModelDownloadService.instance
        .progressFor(LocalSttModelType.moonshine)
        .value;
    _moonshineDownloadState = current.state;
    _moonshineDownloadProgress = current.progress;
    _moonshineBytesDownloaded = current.bytesDownloaded;
    _moonshineTotalBytes = current.totalBytes;
    _moonshineSpeedBytesPerSec = current.speedBytesPerSec;
    _moonshineErrorMessage = current.errorMessage;
    _moonshineErrorLog = current.errorLog;
    _moonshineCurrentFile = current.currentFile;
  }

  void _onParakeetProgressChanged() {
    _syncParakeetState();
    notifyListeners();
  }

  void _onMoonshineProgressChanged() {
    _syncMoonshineState();
    notifyListeners();
  }

  Future<void> _checkDeviceRam() async {
    _deviceRamWarning = await ModelDownloadService.instance.isLowRamDevice();
    notifyListeners();
  }

  // --- Download actions ---
  Future<void> startDownload([
    LocalSttModelType type = LocalSttModelType.parakeet,
  ]) async {
    await ModelDownloadService.instance.downloadModel(type);
  }

  void cancelDownload() {
    ModelDownloadService.instance.cancelDownload();
  }

  Future<void> deleteModel([
    LocalSttModelType type = LocalSttModelType.parakeet,
  ]) async {
    await ModelDownloadService.instance.deleteModel(type);
  }

  void toggleAutoFallback() {
    final current = SharedPreferencesUtil().localSttAutoFallback;
    SharedPreferencesUtil().localSttAutoFallback = !current;
    notifyListeners();
  }

  // --- Speaker model methods ---
  void _onSpeakerProgressChanged() {
    final progress =
        SpeakerModelDownloadService.instance.downloadProgress.value;
    _speakerDownloadState = progress.state;
    _speakerDownloadProgress = progress.progress;
    notifyListeners();
  }

  Future<void> startSpeakerModelDownload() async {
    await SpeakerModelDownloadService.instance.downloadModel();
  }

  void cancelSpeakerModelDownload() {
    SpeakerModelDownloadService.instance.cancelDownload();
  }

  Future<void> deleteSpeakerModel() async {
    await SpeakerModelDownloadService.instance.deleteModel();
  }

  @override
  void dispose() {
    ModelDownloadService.instance
        .progressFor(LocalSttModelType.parakeet)
        .removeListener(_onParakeetProgressChanged);
    ModelDownloadService.instance
        .progressFor(LocalSttModelType.moonshine)
        .removeListener(_onMoonshineProgressChanged);
    SpeakerModelDownloadService.instance.downloadProgress
        .removeListener(_onSpeakerProgressChanged);
    super.dispose();
  }
}
