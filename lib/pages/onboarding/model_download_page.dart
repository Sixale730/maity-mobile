import 'package:flutter/material.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/home/page.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/stt/local/model_download_service.dart';
import 'package:omi/services/stt/local/local_stt_model_type.dart';
import 'package:omi/services/stt/local/speaker_model_download_service.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/l10n/app_localizations.dart';

enum _Phase { parakeet, speaker, done }

class ModelDownloadPage extends StatefulWidget {
  const ModelDownloadPage({super.key});

  /// Returns the appropriate destination: ModelDownloadPage if models are
  /// missing, HomePageWrapper if all models are ready.
  static Widget destinationAfterOnboarding() {
    final parakeetReady = SharedPreferencesUtil().localSttModelDownloaded;
    final speakerReady = SharedPreferencesUtil().speakerModelDownloaded;
    if (!parakeetReady || !speakerReady) {
      return const ModelDownloadPage();
    }
    return const HomePageWrapper();
  }

  @override
  State<ModelDownloadPage> createState() => _ModelDownloadPageState();
}

class _ModelDownloadPageState extends State<ModelDownloadPage> {
  _Phase _phase = _Phase.parakeet;
  bool _hasError = false;
  String _errorMessage = '';
  double _progress = 0.0;

  VoidCallback? _parakeetListener;
  VoidCallback? _speakerListener;

  @override
  void initState() {
    super.initState();

    _parakeetListener = _onParakeetProgress;
    _speakerListener = _onSpeakerProgress;

    ModelDownloadService.instance
        .progressFor(LocalSttModelType.parakeet)
        .addListener(_parakeetListener!);
    SpeakerModelDownloadService.instance.downloadProgress
        .addListener(_speakerListener!);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startDownloads();
    });
  }

  @override
  void dispose() {
    if (_parakeetListener != null) {
      ModelDownloadService.instance
          .progressFor(LocalSttModelType.parakeet)
          .removeListener(_parakeetListener!);
    }
    if (_speakerListener != null) {
      SpeakerModelDownloadService.instance.downloadProgress
          .removeListener(_speakerListener!);
    }
    super.dispose();
  }

  void _onParakeetProgress() {
    if (_phase != _Phase.parakeet) return;
    final p = ModelDownloadService.instance
        .progressFor(LocalSttModelType.parakeet)
        .value;
    if (!mounted) return;
    setState(() {
      _progress = p.progress;
      if (p.state == DownloadState.error) {
        _hasError = true;
        _errorMessage = p.errorMessage ?? '';
      }
    });
  }

  void _onSpeakerProgress() {
    if (_phase != _Phase.speaker) return;
    final p = SpeakerModelDownloadService.instance.downloadProgress.value;
    if (!mounted) return;
    setState(() {
      _progress = p.progress;
      if (p.state == DownloadState.error) {
        _hasError = true;
        _errorMessage = p.errorMessage ?? '';
      }
    });
  }

  Future<void> _startDownloads() async {
    // Check connectivity
    await ConnectivityService().initialized;
    if (!mounted) return;
    if (!ConnectivityService().isConnected) {
      setState(() {
        _hasError = true;
        _errorMessage = AppLocalizations.of(context)?.downloadNoInternet ??
            'Se requiere conexion a internet para descargar los modelos.';
      });
      return;
    }

    // Phase 1: Parakeet
    final parakeetReady = ModelDownloadService.instance
        .isModelReadyFor(LocalSttModelType.parakeet);
    if (!parakeetReady) {
      setState(() {
        _phase = _Phase.parakeet;
        _progress = 0.0;
        _hasError = false;
      });

      final success = await ModelDownloadService.instance
          .downloadModel(LocalSttModelType.parakeet);
      if (!mounted) return;
      if (!success) {
        setState(() {
          _hasError = true;
          final p = ModelDownloadService.instance
              .progressFor(LocalSttModelType.parakeet)
              .value;
          _errorMessage = p.errorMessage ?? '';
        });
        return;
      }
    }

    // Phase 2: Speaker model
    final speakerReady = SpeakerModelDownloadService.instance.isModelReady;
    if (!speakerReady) {
      setState(() {
        _phase = _Phase.speaker;
        _progress = 0.0;
        _hasError = false;
      });

      final success =
          await SpeakerModelDownloadService.instance.downloadModel();
      if (!mounted) return;
      if (!success) {
        setState(() {
          _hasError = true;
          final p =
              SpeakerModelDownloadService.instance.downloadProgress.value;
          _errorMessage = p.errorMessage ?? '';
        });
        return;
      }
    }

    // Both done
    _navigateToHome();
  }

  void _navigateToHome() {
    if (!mounted) return;
    routeToPage(context, const HomePageWrapper(), replace: true);
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _errorMessage = '';
    });
    _startDownloads();
  }

  String _phaseText(AppLocalizations? l10n) {
    switch (_phase) {
      case _Phase.parakeet:
        final p = ModelDownloadService.instance
            .progressFor(LocalSttModelType.parakeet)
            .value;
        if (p.state == DownloadState.validating) {
          return l10n?.validatingModel ?? 'Verificando...';
        }
        return l10n?.downloadingTranscriptionModel ??
            'Descargando modelo de transcripcion...';
      case _Phase.speaker:
        final p = SpeakerModelDownloadService.instance.downloadProgress.value;
        if (p.state == DownloadState.validating) {
          return l10n?.validatingModel ?? 'Verificando...';
        }
        return l10n?.downloadingSpeakerModel ??
            'Descargando modelo de identificacion de voz...';
      case _Phase.done:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // Determine if spinner should be indeterminate (validating state)
    final bool isValidating = (_phase == _Phase.parakeet &&
            ModelDownloadService.instance
                    .progressFor(LocalSttModelType.parakeet)
                    .value
                    .state ==
                DownloadState.validating) ||
        (_phase == _Phase.speaker &&
            SpeakerModelDownloadService
                    .instance.downloadProgress.value.state ==
                DownloadState.validating);

    final displayProgress = isValidating ? null : _progress;
    final percentText =
        isValidating ? '...' : '${(_progress * 100).toInt()}%';

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.primary,
        body: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // Spinner with percentage
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 140,
                    height: 140,
                    child: CircularProgressIndicator(
                      value: displayProgress,
                      strokeWidth: 6,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  Text(
                    percentText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              // Phase description
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  _phaseText(l10n),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const Spacer(),
              // Error state
              if (_hasError) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    _errorMessage.isNotEmpty
                        ? _errorMessage
                        : (l10n?.downloadErrorMessage ??
                            'Error en la descarga. Verifica tu conexion a internet.'),
                    style: TextStyle(
                      color: Colors.red.shade300,
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                MaterialButton(
                  onPressed: _retry,
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  child: Text(
                    l10n?.downloadErrorRetry ?? 'Reintentar',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}
