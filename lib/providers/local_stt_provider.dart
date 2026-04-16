import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/services/stt/local/device_memory_service.dart';
import 'package:omi/services/stt/local/local_stt_engine_service.dart';
import 'package:omi/services/stt/local/local_stt_model_type.dart';
import 'package:omi/services/stt/local/model_download_service.dart';
import 'package:omi/services/stt/local/speaker_model_download_service.dart';

class LocalSttProvider extends ChangeNotifier {
  bool _deviceRamWarning = false;

  // Speaker model state
  DownloadState _speakerDownloadState = DownloadState.idle;
  double _speakerDownloadProgress = 0.0;

  // --- Warm-up state ---
  /// Connected engine kept alive between recordings to eliminate the
  /// 2-4 s cold-start latency (model load + isolate spawn). Null when the
  /// engine hasn't been warmed yet, was disposed after idle, or the user's
  /// STT provider is cloud.
  LocalSttEngineService? _warmEngine;

  /// In-flight warm-up future so concurrent callers wait instead of creating
  /// a second engine.
  Future<void>? _warmUpInFlight;

  /// True while the pipeline is actively using the warm engine for a
  /// recording. Prevents the idle timer from disposing it mid-session.
  bool _engineInUse = false;

  /// The model type the warm engine was built for. Used to detect stale
  /// engines after the user switches models in Settings.
  LocalSttModelType? _warmEngineModel;

  /// After a recording releases the engine, give the user 60 s to record
  /// again before we tear it down and free the ~640 MB of model RAM.
  Timer? _idleDisposeTimer;
  static const Duration _idleDisposeAfter = Duration(seconds: 60);

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
    final previous = SharedPreferencesUtil().activeLocalSttModel;
    SharedPreferencesUtil().activeLocalSttModel = type.name;
    // If the user switched models, the currently-warm engine is stale —
    // dispose it so the next recording builds a fresh one with the new
    // model path. If the warm engine was already using the selected model,
    // keep it.
    if (previous != type.name && _warmEngine != null) {
      unawaited(_disposeWarmEngine(reason: 'model changed'));
    }
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

  // ---------------------------------------------------------------------------
  // Engine warm-up
  // ---------------------------------------------------------------------------

  /// True when the warm engine is alive and connected (ready for acquire).
  /// Useful for tests + diagnostics; UI doesn't care about this.
  bool get isEngineWarm => _warmEngine?.isConnected ?? false;

  /// Kick off (or join) the engine warm-up. Safe to call from
  /// [HomePage.initState] — idempotent and gated so low-RAM devices skip it.
  ///
  /// Gating:
  /// - User's active STT provider is local (Parakeet / Moonshine / Canary).
  /// - Selected model is downloaded and ready.
  /// - Device is not low-tier (< 2 GB free — holding ~640 MB permanently
  ///   would starve other apps).
  ///
  /// Errors are swallowed — if warm-up fails the recording path falls back
  /// to cold-start as it did before.
  Future<void> warmUpEngine() async {
    // Already warm or a warm-up is already running: reuse it.
    if (_warmEngine?.isConnected == true) return;
    if (_warmUpInFlight != null) return _warmUpInFlight;

    if (!_shouldWarm()) return;

    final type = selectedModel;
    if (!isReadyFor(type)) {
      debugPrint(
          '[LocalSttProvider] Skipping warm-up: $type not ready.');
      return;
    }

    final engine = LocalSttEngineService.fromPreferences(type);
    if (engine == null) return;

    _warmEngineModel = type;
    _warmUpInFlight = _doWarmUp(engine);
    try {
      await _warmUpInFlight;
    } finally {
      _warmUpInFlight = null;
    }
  }

  Future<void> _doWarmUp(LocalSttEngineService engine) async {
    debugPrint('[LocalSttProvider] Warming up engine (${_warmEngineModel?.name})...');
    final stopwatch = Stopwatch()..start();
    try {
      final ok = await engine.connect();
      stopwatch.stop();
      if (!ok) {
        debugPrint('[LocalSttProvider] Warm-up failed');
        return;
      }
      _warmEngine = engine;
      debugPrint(
          '[LocalSttProvider] Engine warm in ${stopwatch.elapsedMilliseconds} ms');
    } catch (e) {
      debugPrint('[LocalSttProvider] Warm-up error: $e');
    }
  }

  /// Return the pre-warmed engine if one is ready and built for the active
  /// model. Marks it as in-use so the idle timer doesn't tear it down while
  /// a recording is in progress. Returns null to signal the caller should
  /// fall back to building a new engine cold.
  LocalSttEngineService? acquireEngine() {
    final engine = _warmEngine;
    if (engine == null) return null;
    if (!engine.isConnected) return null;
    // Stale guard: if the user switched models after warm-up, the engine
    // can't serve the new model. selectModel() already disposes in that
    // case, but double-check here to be safe.
    if (_warmEngineModel != null && _warmEngineModel != selectedModel) {
      unawaited(_disposeWarmEngine(reason: 'stale model'));
      return null;
    }
    _engineInUse = true;
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = null;
    return engine;
  }

  /// Hand the engine back after a recording ends. Starts the idle timer so
  /// the engine is disposed if the user doesn't record again within
  /// [_idleDisposeAfter]. The engine reference is kept (not the concrete
  /// object the pipeline had) so ownership stays with the provider.
  void releaseEngine(LocalSttEngineService engine) {
    if (!identical(engine, _warmEngine)) {
      // Released engine was a cold-built one, not owned by us. Let caller
      // dispose it normally.
      return;
    }
    _engineInUse = false;
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = Timer(_idleDisposeAfter, () {
      if (_engineInUse) return;
      unawaited(_disposeWarmEngine(reason: 'idle timeout'));
    });
  }

  /// Gating helper: whether this device + config should get a pre-warmed
  /// engine. Low-tier devices get the old cold-start behaviour.
  bool _shouldWarm() {
    final config = SharedPreferencesUtil().customSttConfig;
    if (!config.isEnabled) return false;
    final isLocalProvider = config.provider == SttProvider.localParakeet ||
        config.provider == SttProvider.localMoonshine ||
        config.provider == SttProvider.localCanary;
    if (!isLocalProvider) return false;
    if (DeviceMemoryService.cachedTier == DeviceTier.low) return false;
    return true;
  }

  Future<void> _disposeWarmEngine({required String reason}) async {
    final engine = _warmEngine;
    if (engine == null) return;
    debugPrint('[LocalSttProvider] Disposing warm engine ($reason)');
    _warmEngine = null;
    _warmEngineModel = null;
    _engineInUse = false;
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = null;
    try {
      await engine.disconnect();
    } catch (e) {
      debugPrint('[LocalSttProvider] disconnect error (ignored): $e');
    }
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
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = null;
    if (_warmEngine != null) {
      unawaited(_disposeWarmEngine(reason: 'provider disposed'));
    }
    super.dispose();
  }
}
