import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/local_stt/model_download_service.dart';
import 'package:omi/services/local_stt/speaker_model_download_service.dart';

class LocalSttProvider extends ChangeNotifier {
  DownloadState _downloadState = DownloadState.idle;
  double _downloadProgress = 0.0;
  int _bytesDownloaded = 0;
  int _totalBytes = 0;
  double _speedBytesPerSec = 0.0;
  String? _errorMessage;
  String? _errorLog;
  String? _currentFile;
  bool _deviceRamWarning = false;

  // Speaker model state
  DownloadState _speakerDownloadState = DownloadState.idle;
  double _speakerDownloadProgress = 0.0;

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
  bool get autoFallbackEnabled => SharedPreferencesUtil().localSttAutoFallback;

  // Speaker model getters
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
    // Listen to ModelDownloadService progress
    ModelDownloadService.instance.downloadProgress.addListener(_onProgressChanged);

    // Listen to SpeakerModelDownloadService progress
    SpeakerModelDownloadService.instance.downloadProgress
        .addListener(_onSpeakerProgressChanged);

    // Sync initial state
    final current = ModelDownloadService.instance.downloadProgress.value;
    _downloadState = current.state;
    _downloadProgress = current.progress;

    final speakerCurrent =
        SpeakerModelDownloadService.instance.downloadProgress.value;
    _speakerDownloadState = speakerCurrent.state;
    _speakerDownloadProgress = speakerCurrent.progress;

    // Check RAM on init
    _checkDeviceRam();
  }

  void _onProgressChanged() {
    final progress = ModelDownloadService.instance.downloadProgress.value;
    _downloadState = progress.state;
    _downloadProgress = progress.progress;
    _bytesDownloaded = progress.bytesDownloaded;
    _totalBytes = progress.totalBytes;
    _speedBytesPerSec = progress.speedBytesPerSec;
    _errorMessage = progress.errorMessage;
    _errorLog = progress.errorLog;
    _currentFile = progress.currentFile;
    notifyListeners();
  }

  Future<void> _checkDeviceRam() async {
    _deviceRamWarning = await ModelDownloadService.instance.isLowRamDevice();
    notifyListeners();
  }

  Future<void> startDownload() async {
    await ModelDownloadService.instance.downloadModel();
  }

  void cancelDownload() {
    ModelDownloadService.instance.cancelDownload();
  }

  Future<void> deleteModel() async {
    await ModelDownloadService.instance.deleteModel();
  }

  void toggleAutoFallback() {
    final current = SharedPreferencesUtil().localSttAutoFallback;
    SharedPreferencesUtil().localSttAutoFallback = !current;
    notifyListeners();
  }

  // Speaker model methods
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
    ModelDownloadService.instance.downloadProgress.removeListener(_onProgressChanged);
    SpeakerModelDownloadService.instance.downloadProgress
        .removeListener(_onSpeakerProgressChanged);
    super.dispose();
  }
}
