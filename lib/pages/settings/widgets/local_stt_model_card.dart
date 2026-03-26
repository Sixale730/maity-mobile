import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/local_stt_provider.dart';
import 'package:omi/services/local_stt/model_download_service.dart';
import 'package:provider/provider.dart';

class LocalSttModelCard extends StatelessWidget {
  const LocalSttModelCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<LocalSttProvider>(
      builder: (context, provider, _) {
        final l10n = AppLocalizations.of(context)!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Description
            Text(
              l10n.localSttDescription,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.localSttModelSize,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 16),

            // RAM warning
            if (provider.deviceRamWarning) ...[
              _buildRamWarning(l10n),
              const SizedBox(height: 12),
            ],

            // Main content based on state
            _buildStateContent(context, provider, l10n),

            const SizedBox(height: 16),

            // Speaker ID model section (only when STT model is ready)
            if (provider.isModelReady) ...[
              _buildSpeakerIdSection(context, provider),
              const SizedBox(height: 16),
            ],

            // Auto-fallback toggle (only when model is ready)
            if (provider.isModelReady) _buildAutoFallbackToggle(provider, l10n),
          ],
        );
      },
    );
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
          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade400, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.localSttRamWarning,
              style: TextStyle(color: Colors.orange.shade300, fontSize: 12, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStateContent(BuildContext context, LocalSttProvider provider, AppLocalizations l10n) {
    switch (provider.downloadState) {
      case DownloadState.downloading:
      case DownloadState.validating:
        return _buildDownloadingState(provider, l10n);
      case DownloadState.ready:
        return _buildReadyState(context, provider, l10n);
      case DownloadState.error:
        return _buildErrorState(context, provider, l10n);
      default:
        return _buildIdleState(provider, l10n);
    }
  }

  Widget _buildIdleState(LocalSttProvider provider, AppLocalizations l10n) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: () => provider.startDownload(),
        icon: const Icon(Icons.download_rounded, size: 20),
        label: Text(l10n.localSttDownloadModel),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildDownloadingState(LocalSttProvider provider, AppLocalizations l10n) {
    final progress = provider.downloadProgress;
    final speedMb = provider.speedBytesPerSec / (1024 * 1024);
    final downloadedMb = provider.bytesDownloaded / (1024 * 1024);
    final totalMb = provider.totalBytes / (1024 * 1024);

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
              if (provider.downloadState == DownloadState.validating)
                Text(
                  'Validating...',
                  style: TextStyle(color: Colors.grey.shade300, fontSize: 14, fontWeight: FontWeight.w500),
                )
              else
                Text(
                  l10n.localSttDownloading,
                  style: TextStyle(color: Colors.grey.shade300, fontSize: 14, fontWeight: FontWeight.w500),
                ),
              const Spacer(),
              Text(
                '${(progress * 100).toStringAsFixed(1)}%',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
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
          if (provider.currentFile != null) ...[
            const SizedBox(height: 4),
            Text(
              provider.currentFile!,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 10, fontFamily: 'monospace'),
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(l10n.cancel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadyState(BuildContext context, LocalSttProvider provider, AppLocalizations l10n) {
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
              Icon(Icons.check_circle, color: Colors.green.shade400, size: 22),
              const SizedBox(width: 10),
              Text(
                l10n.localSttReady,
                style: TextStyle(color: Colors.green.shade400, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton.icon(
              onPressed: () => _confirmDelete(context, provider, l10n),
              icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
              label: Text(l10n.localSttDeleteModel),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade400,
                side: BorderSide(color: Colors.red.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, LocalSttProvider provider, AppLocalizations l10n) {
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
              Icon(Icons.error_outline, color: Colors.red.shade400, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  provider.errorMessage ?? l10n.error,
                  style: TextStyle(color: Colors.red.shade300, fontSize: 13),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (provider.errorLog != null)
                IconButton(
                  icon: Icon(Icons.copy_rounded, color: Colors.grey.shade500, size: 18),
                  tooltip: l10n.copiedToClipboard,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: provider.errorLog!));
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
              onPressed: () => provider.startDownload(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              child: Text(l10n.retry),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoFallbackToggle(LocalSttProvider provider, AppLocalizations l10n) {
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
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.localSttAutoFallbackDesc,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
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

  Widget _buildSpeakerIdSection(BuildContext context, LocalSttProvider provider) {
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
              Icon(Icons.check_circle, color: Colors.green.shade400, size: 18),
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
              onPressed: () => _confirmDeleteSpeakerModel(context, provider),
              icon: Icon(Icons.delete_outline,
                  size: 16, color: Colors.red.shade400),
              label: Text('Delete Speaker Model',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
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
            child:
                Text('Cancel', style: TextStyle(color: Colors.grey.shade400)),
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

  void _confirmDelete(BuildContext context, LocalSttProvider provider, AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(l10n.localSttDeleteModel, style: const TextStyle(color: Colors.white)),
        content: Text(l10n.localSttDeleteConfirm, style: TextStyle(color: Colors.grey.shade300)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel, style: TextStyle(color: Colors.grey.shade400)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              provider.deleteModel();
            },
            child: Text(l10n.delete, style: TextStyle(color: Colors.red.shade400)),
          ),
        ],
      ),
    );
  }
}
