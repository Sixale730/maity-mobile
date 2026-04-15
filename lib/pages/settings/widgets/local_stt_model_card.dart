import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/local_stt_provider.dart';
import 'package:omi/providers/role_provider.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/model_download_service.dart';
import 'package:omi/pages/speech_profile/page.dart';
import 'package:omi/utils/enums.dart';
import 'package:provider/provider.dart';

class LocalSttModelCard extends StatelessWidget {
  const LocalSttModelCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<LocalSttProvider>(
      builder: (context, provider, _) {
        final l10n = AppLocalizations.of(context)!;
        final selected = provider.selectedModel;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Model selector dropdown
            _buildModelDropdown(context, provider, selected),
            const SizedBox(height: 12),

            // Description for selected model
            Text(
              _descriptionFor(selected),
              style: TextStyle(
                  color: Colors.grey.shade500, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              _sizeTextFor(selected),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 16),

            // RAM warning
            if (provider.deviceRamWarning) ...[
              _buildRamWarning(l10n),
              const SizedBox(height: 12),
            ],

            // Main content based on selected model's state
            _buildStateContent(context, provider, l10n, selected),

            const SizedBox(height: 16),

            // Speaker ID model section (only when any model is ready)
            if (provider.isReadyFor(selected)) ...[
              _buildSpeakerIdSection(context, provider),
              const SizedBox(height: 16),
            ],

            // Auto-fallback toggle (only when any model is ready)
            if (provider.isReadyFor(selected))
              _buildAutoFallbackToggle(provider, l10n),

            // Streaming kill switch (admin-only). Lets us disable the
            // in-memory streaming fast path without redeploy if it misbehaves.
            if (provider.isReadyFor(selected) &&
                context.read<RoleProvider>().isAdmin) ...[
              const SizedBox(height: 8),
              _buildStreamingToggle(context),
            ],

            // Canary max speech duration slider
            if (selected == LocalSttModelType.canary &&
                provider.isReadyFor(LocalSttModelType.canary))
              _buildCanaryMaxDurationSlider(),
          ],
        );
      },
    );
  }

  Widget _buildModelDropdown(
    BuildContext context,
    LocalSttProvider provider,
    LocalSttModelType selected,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LocalSttModelType>(
          value: selected,
          isExpanded: true,
          dropdownColor: const Color(0xFF1A1A1A),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          icon: Icon(Icons.keyboard_arrow_down_rounded,
              color: Colors.grey.shade400),
          items: [
            DropdownMenuItem(
              value: LocalSttModelType.parakeet,
              child: Row(
                children: [
                  Icon(Icons.memory_rounded,
                      size: 18, color: Colors.blue.shade300),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Parakeet (25 languages, ~640 MB)'),
                  ),
                  if (provider.isReadyFor(LocalSttModelType.parakeet))
                    Icon(Icons.check_circle,
                        size: 16, color: Colors.green.shade400),
                ],
              ),
            ),
            DropdownMenuItem(
              value: LocalSttModelType.moonshine,
              child: Row(
                children: [
                  Icon(Icons.nightlight_round,
                      size: 18, color: Colors.purple.shade300),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Moonshine ES (Spanish, ~50 MB)'),
                  ),
                  if (provider.isReadyFor(LocalSttModelType.moonshine))
                    Icon(Icons.check_circle,
                        size: 16, color: Colors.green.shade400),
                ],
              ),
            ),
            DropdownMenuItem(
              value: LocalSttModelType.canary,
              child: Row(
                children: [
                  Icon(Icons.pets_rounded,
                      size: 18, color: Colors.amber.shade300),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Canary (es/en/de/fr, ~208 MB)'),
                  ),
                  if (provider.isReadyFor(LocalSttModelType.canary))
                    Icon(Icons.check_circle,
                        size: 16, color: Colors.green.shade400),
                ],
              ),
            ),
          ],
          onChanged: (type) {
            if (type == null || type == selected) return;
            _onModelChanged(context, provider, type);
          },
        ),
      ),
    );
  }

  void _onModelChanged(
    BuildContext context,
    LocalSttProvider provider,
    LocalSttModelType newType,
  ) {
    final capture = Provider.of<CaptureProvider>(context, listen: false);
    final isRecording = capture.recordingState == RecordingState.record ||
        capture.recordingState == RecordingState.deviceRecord ||
        capture.recordingState == RecordingState.systemAudioRecord ||
        capture.recordingState == RecordingState.pause;

    final activeProvider = capture.activeSttProvider;
    final isUsingLocalStt = activeProvider == SttProvider.localParakeet ||
        activeProvider == SttProvider.localMoonshine ||
        activeProvider == SttProvider.localCanary;

    if (isRecording && isUsingLocalStt) {
      final isNewModelReady = provider.isReadyFor(newType);
      showDialog(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1F1F25),
            title: const Text('Cambiar modelo durante grabación'),
            content: Text(
              isNewModelReady
                  ? 'Se cambiará el modelo STT sin detener la grabación. '
                    'Los segmentos anteriores se conservan.'
                  : 'El modelo ${newType.name} no está descargado. '
                    'Se guardará la preferencia pero seguirá usando el modelo actual hasta que descargues el nuevo.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancelar'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  provider.selectModel(newType);
                  if (isNewModelReady) {
                    await capture.onTranscriptionSettingsChanged();
                  }
                },
                child: Text(isNewModelReady ? 'Cambiar' : 'Aceptar'),
              ),
            ],
          );
        },
      );
    } else {
      provider.selectModel(newType);
    }
  }

  String _descriptionFor(LocalSttModelType type) {
    switch (type) {
      case LocalSttModelType.parakeet:
        return 'NVIDIA Parakeet TDT 0.6B — Fast offline transcription supporting 25 languages with auto-detection.';
      case LocalSttModelType.moonshine:
        return 'Moonshine v2 Base — Optimized for Spanish offline transcription. Smaller and faster download.';
      case LocalSttModelType.canary:
        return 'NVIDIA Canary 180M Flash — Best Spanish accuracy (3.17% WER). Supports en/es/de/fr.';
    }
  }

  String _sizeTextFor(LocalSttModelType type) {
    switch (type) {
      case LocalSttModelType.parakeet:
        return 'Model size: ~640 MB';
      case LocalSttModelType.moonshine:
        return 'Model size: ~50 MB (compressed)';
      case LocalSttModelType.canary:
        return 'Model size: ~208 MB';
    }
  }

  Widget _buildRamWarning(AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              color: Colors.orange.shade400, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.localSttRamWarning,
              style: TextStyle(
                  color: Colors.orange.shade300, fontSize: 12, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStateContent(
    BuildContext context,
    LocalSttProvider provider,
    AppLocalizations l10n,
    LocalSttModelType type,
  ) {
    final state = provider.stateFor(type);
    switch (state) {
      case DownloadState.downloading:
      case DownloadState.validating:
        return _buildDownloadingState(provider, l10n, type);
      case DownloadState.ready:
        return _buildReadyState(context, provider, l10n, type);
      case DownloadState.error:
        return _buildErrorState(context, provider, l10n, type);
      default:
        return _buildIdleState(provider, l10n, type);
    }
  }

  Widget _buildIdleState(
      LocalSttProvider provider, AppLocalizations l10n, LocalSttModelType type) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: () => provider.startDownload(type),
        icon: const Icon(Icons.download_rounded, size: 20),
        label: Text(l10n.localSttDownloadModel),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildDownloadingState(
      LocalSttProvider provider, AppLocalizations l10n, LocalSttModelType type) {
    final double progress;
    final double speedMb;
    final double downloadedMb;
    final double totalMb;
    final DownloadState state;
    final String? file;

    progress = provider.progressFor(type);
    speedMb = provider.speedFor(type) / (1024 * 1024);
    downloadedMb = provider.bytesDownloadedFor(type) / (1024 * 1024);
    totalMb = provider.totalBytesFor(type) / (1024 * 1024);
    state = provider.stateFor(type);
    file = provider.currentFileFor(type);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (state == DownloadState.validating)
                Text(
                  'Extracting...',
                  style: TextStyle(
                      color: Colors.grey.shade300,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                )
              else
                Text(
                  l10n.localSttDownloading,
                  style: TextStyle(
                      color: Colors.grey.shade300,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                ),
              const Spacer(),
              Text(
                '${(progress * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey.shade800,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '${downloadedMb.toStringAsFixed(0)} / ${totalMb.toStringAsFixed(0)} MB',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
              const Spacer(),
              if (speedMb > 0)
                Text(
                  '${speedMb.toStringAsFixed(1)} MB/s',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                ),
            ],
          ),
          if (file != null) ...[
            const SizedBox(height: 4),
            Text(
              file,
              style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 10,
                  fontFamily: 'monospace'),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton(
              onPressed: () => provider.cancelDownload(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade400,
                side: BorderSide(color: Colors.grey.shade700),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(l10n.cancel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadyState(BuildContext context, LocalSttProvider provider,
      AppLocalizations l10n, LocalSttModelType type) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.check_circle,
                  color: Colors.green.shade400, size: 22),
              const SizedBox(width: 10),
              Text(
                l10n.localSttReady,
                style: TextStyle(
                    color: Colors.green.shade400,
                    fontSize: 15,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton.icon(
              onPressed: () => _confirmDelete(context, provider, l10n, type),
              icon: Icon(Icons.delete_outline,
                  size: 18, color: Colors.red.shade400),
              label: Text(l10n.localSttDeleteModel),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade400,
                side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, LocalSttProvider provider,
      AppLocalizations l10n, LocalSttModelType type) {
    final errorMsg = provider.errorMessageFor(type);
    final errorLog = provider.errorLogFor(type);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline,
                  color: Colors.red.shade400, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  errorMsg ?? l10n.error,
                  style: TextStyle(color: Colors.red.shade300, fontSize: 13),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (errorLog != null)
                IconButton(
                  icon: Icon(Icons.copy_rounded,
                      color: Colors.grey.shade500, size: 18),
                  tooltip: l10n.copiedToClipboard,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: errorLog));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.copiedToClipboard),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: ElevatedButton(
              onPressed: () => provider.startDownload(type),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              child: Text(l10n.retry),
            ),
          ),
        ],
      ),
    );
  }

  /// Admin-only kill switch for the streaming fast path. Reads and writes
  /// [SharedPreferencesUtil.useStreamingPipeline]. Uses a [StatefulBuilder]
  /// so the switch reflects the new state without rebuilding the whole card,
  /// since the preference is not exposed through a ChangeNotifier.
  Widget _buildStreamingToggle(BuildContext context) {
    final prefs = SharedPreferencesUtil();
    return StatefulBuilder(
      builder: (context, setLocalState) {
        final enabled = prefs.useStreamingPipeline;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade800),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Streaming fast path (admin)',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Transcribe directo en memoria (~<1s). Si lo apagas, vuelve al pipeline chunk-based de 5s.',
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (v) {
                  prefs.useStreamingPipeline = v;
                  setLocalState(() {});
                },
                activeThumbColor: Colors.white,
                activeTrackColor: Colors.green,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAutoFallbackToggle(
      LocalSttProvider provider, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.localSttAutoFallback,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.localSttAutoFallbackDesc,
                  style:
                      TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(
            value: provider.autoFallbackEnabled,
            onChanged: (_) => provider.toggleAutoFallback(),
            activeThumbColor: Colors.white,
            activeTrackColor: Colors.green,
          ),
        ],
      ),
    );
  }

  Widget _buildCanaryMaxDurationSlider() {
    final prefs = SharedPreferencesUtil();
    return StatefulBuilder(
      builder: (context, setLocalState) {
        double value = prefs.localSttCanaryMaxSpeechDuration;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade800),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Duración máx. segmento: ${value.toInt()}s',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                  if (value != 5.0)
                    GestureDetector(
                      onTap: () {
                        prefs.localSttCanaryMaxSpeechDuration = 5.0;
                        setLocalState(() {});
                      },
                      child: Text(
                        'Default',
                        style: TextStyle(
                            color: Colors.blue.shade400, fontSize: 12),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Segmentos más cortos = transcripción más rápida',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              Slider(
                value: value,
                min: 3,
                max: 30,
                divisions: 27,
                label: '${value.toInt()}s',
                activeColor: Colors.blue,
                onChanged: (v) {
                  prefs.localSttCanaryMaxSpeechDuration = v.roundToDouble();
                  setLocalState(() {});
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSpeakerIdSection(
      BuildContext context, LocalSttProvider provider) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.record_voice_over_rounded,
                  color: Colors.grey.shade300, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Speaker Identification',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Identify who is speaking during local transcription',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _buildSpeakerModelState(context, provider),
        ],
      ),
    );
  }

  Widget _buildSpeakerModelState(
      BuildContext context, LocalSttProvider provider) {
    if (provider.isSpeakerModelReady) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle,
                  color: Colors.green.shade400, size: 18),
              const SizedBox(width: 8),
              Text(
                'Speaker Model Ready',
                style: TextStyle(
                    color: Colors.green.shade400,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
          if (!provider.hasLocalSpeakerEmbedding) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.info_outline,
                    color: Colors.orange.shade400, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Enroll your voice profile to enable speaker identification',
                    style: TextStyle(
                        color: Colors.orange.shade400, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SpeechProfilePage()),
                  );
                },
                icon: const Icon(Icons.record_voice_over_rounded, size: 18),
                label: const Text('Crear perfil de voz'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              'Your voice profile is enrolled for local identification',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 36,
            child: OutlinedButton.icon(
              onPressed: () =>
                  _confirmDeleteSpeakerModel(context, provider),
              icon: Icon(Icons.delete_outline,
                  size: 16, color: Colors.red.shade400),
              label: Text('Delete Speaker Model',
                  style:
                      TextStyle(fontSize: 12, color: Colors.red.shade400)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade400,
                side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      );
    }

    if (provider.isSpeakerModelDownloading) {
      return Column(
        children: [
          Row(
            children: [
              const Text(
                'Downloading...',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              const Spacer(),
              Text(
                '${(provider.speakerDownloadProgress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: provider.speakerDownloadProgress,
              backgroundColor: Colors.grey.shade800,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 32,
            child: OutlinedButton(
              onPressed: () => provider.cancelSpeakerModelDownload(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade400,
                side: BorderSide(color: Colors.grey.shade700),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Cancel', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      );
    }

    // Idle or error state — show download button
    return SizedBox(
      width: double.infinity,
      height: 40,
      child: ElevatedButton.icon(
        onPressed: () => provider.startSpeakerModelDownload(),
        icon: const Icon(Icons.download_rounded, size: 18),
        label: const Text('Download Speaker Model (28 MB)'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey.shade800,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          elevation: 0,
        ),
      ),
    );
  }

  void _confirmDeleteSpeakerModel(
      BuildContext context, LocalSttProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete Speaker Model',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'This will remove the speaker identification model and your local voice embedding.',
          style: TextStyle(color: Colors.grey.shade300),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel',
                style: TextStyle(color: Colors.grey.shade400)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              provider.deleteSpeakerModel();
            },
            child: Text('Delete',
                style: TextStyle(color: Colors.red.shade400)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, LocalSttProvider provider,
      AppLocalizations l10n, LocalSttModelType type) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(l10n.localSttDeleteModel,
            style: const TextStyle(color: Colors.white)),
        content: Text(l10n.localSttDeleteConfirm,
            style: TextStyle(color: Colors.grey.shade300)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel,
                style: TextStyle(color: Colors.grey.shade400)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              provider.deleteModel(type);
            },
            child: Text(l10n.delete,
                style: TextStyle(color: Colors.red.shade400)),
          ),
        ],
      ),
    );
  }
}
