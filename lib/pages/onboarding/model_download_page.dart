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

// Sizes used for consent disclosure. Kept in sync with the manifests.
const int _kParakeetSizeMb = 640;
const int _kSpeakerSizeMb = 28;

class _ModelDownloadPageState extends State<ModelDownloadPage> {
  _Phase _phase = _Phase.parakeet;
  bool _hasError = false;
  String _errorMessage = '';
  double _progress = 0.0;

  // Apple Guideline 4.2.3: downloads must not start until the user taps a
  // button that discloses the size. We stay on the consent view until then.
  bool _downloadStarted = false;

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

  void _onDownloadConfirmed() {
    setState(() => _downloadStarted = true);
    _startDownloads();
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

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.primary,
        body: SafeArea(
          child: _downloadStarted
              ? _buildDownloadingView(l10n)
              : _buildConsentView(l10n),
        ),
      ),
    );
  }

  Widget _buildConsentView(AppLocalizations? l10n) {
    final parakeetReady = ModelDownloadService.instance
        .isModelReadyFor(LocalSttModelType.parakeet);
    final speakerReady = SpeakerModelDownloadService.instance.isModelReady;

    final parakeetSize = parakeetReady ? 0 : _kParakeetSizeMb;
    final speakerSize = speakerReady ? 0 : _kSpeakerSizeMb;
    final totalSize = parakeetSize + speakerSize;
    final totalSizeText = totalSize.toString();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          const Center(
            child: Icon(
              Icons.download_for_offline_rounded,
              size: 72,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l10n?.modelDownloadConsentTitle ?? 'Descargar modelos locales',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            l10n?.modelDownloadConsentSubtitle ??
                'Maity necesita descargar los siguientes recursos para funcionar:',
            style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (!parakeetReady)
            _buildModelBullet(
              icon: Icons.memory_rounded,
              label: l10n?.modelDownloadConsentParakeet ??
                  'Modelo de transcripción',
              sizeText: '~$_kParakeetSizeMb MB',
            ),
          if (!speakerReady)
            _buildModelBullet(
              icon: Icons.record_voice_over_rounded,
              label: l10n?.modelDownloadConsentSpeaker ??
                  'Modelo de identificación de voz',
              sizeText: '~$_kSpeakerSizeMb MB',
            ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.sd_storage_rounded,
                    color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n?.modelDownloadConsentTotalSize(totalSizeText) ??
                        'Tamaño total: ~$totalSizeText MB',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.wifi_rounded,
                  color: Colors.amber.shade200, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n?.modelDownloadConsentWifi ??
                      'Se recomienda usar Wi-Fi. La descarga puede tardar varios minutos.',
                  style: TextStyle(
                      color: Colors.amber.shade100,
                      fontSize: 13,
                      height: 1.3),
                ),
              ),
            ],
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _onDownloadConfirmed,
              icon: const Icon(Icons.download_rounded),
              label: Text(
                l10n?.modelDownloadConsentButton(totalSizeText) ??
                    'Descargar ahora (~$totalSizeText MB)',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26)),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildModelBullet({
    required IconData icon,
    required String label,
    required String sizeText,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
          Text(
            sizeText,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadingView(AppLocalizations? l10n) {
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

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),
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
    );
  }
}
