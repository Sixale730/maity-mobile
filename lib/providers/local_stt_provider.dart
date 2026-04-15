import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/stt/local/local_stt_model_type.dart';
import 'package:omi/services/stt/local/model_download_service.dart';
import 'package:omi/services/stt/local/speaker_model_download_service.dart';

class LocalSttProvider extends ChangeNotifier {
  bool _deviceRamWarning = false;

  // Speaker model state
  DownloadState _speakerDownloadState = DownloadState.idle;
  double _speakerDownloadProgress = 0.0;

  // --- Generic per-type getters (reads directly from service) ---

  DownloadState stateFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.state;

  double progressFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.progress;

  int bytesDownloadedFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.bytesDownloaded;

  int totalBytesFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.totalBytes;

  double speedFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.speedBytesPerSec;

  String? errorMessageFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.errorMessage;

  String? errorLogFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.errorLog;

  String? currentFileFor(LocalSttModelType type) =>
      ModelDownloadService.instance.progressFor(type).value.currentFile;

  bool isReadyFor(LocalSttModelType type) =>
      stateFor(type) == DownloadState.ready;

  bool isDownloadingFor(LocalSttModelType type) =>
      stateFor(type) == DownloadState.downloading;

  // --- Backward-compatible Parakeet getters ---
  DownloadState get downloadState => stateFor(LocalSttModelType.parakeet);
  double get downloadProgress => progressFor(LocalSttModelType.parakeet);
  int get bytesDownloaded => bytesDownloadedFor(LocalSttModelType.parakeet);
  int get totalBytes => totalBytesFor(LocalSttModelType.parakeet);
  double get speedBytesPerSec => speedFor(LocalSttModelType.parakeet);
  String? get errorMessage => errorMessageFor(LocalSttModelType.parakeet);
  String? get errorLog => errorLogFor(LocalSttModelType.parakeet);
  String? get currentFile => currentFileFor(LocalSttModelType.parakeet);
  bool get isModelReady => isReadyFor(LocalSttModelType.parakeet);
  bool get isDownloading => isDownloadingFor(LocalSttModelType.parakeet);

  bool get deviceRamWarning => _deviceRamWarning;

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
    // Listen to all model types
    for (final type in LocalSttModelType.values) {
      ModelDownloadService.instance
          .progressFor(type)
          .addListener(_onModelProgressChanged);
    }

    // Listen to SpeakerModelDownloadService progress
    SpeakerModelDownloadService.instance.downloadProgress
        .addListener(_onSpeakerProgressChanged);

    final speakerCurrent =
        SpeakerModelDownloadService.instance.downloadProgress.value;
    _speakerDownloadState = speakerCurrent.state;
    _speakerDownloadProgress = speakerCurrent.progress;

    _checkDeviceRam();
  }

  void _onModelProgressChanged() {
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
    for (final type in LocalSttModelType.values) {
      ModelDownloadService.instance
          .progressFor(type)
          .removeListener(_onModelProgressChanged);
    }
    SpeakerModelDownloadService.instance.downloadProgress
        .removeListener(_onSpeakerProgressChanged);
    super.dispose();
  }
}
