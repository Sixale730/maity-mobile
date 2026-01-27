import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/models/recovery_session.dart';
import 'package:omi/utils/other/temp.dart';

/// Dialog shown when an interrupted recording session is detected
///
/// Allows the user to either recover the session or discard it.
class RecoveryDialog extends StatelessWidget {
  final RecoverySession session;
  final VoidCallback onRecover;
  final VoidCallback onDiscard;

  const RecoveryDialog({
    super.key,
    required this.session,
    required this.onRecover,
    required this.onDiscard,
  });

  /// Show the recovery dialog
  static Future<void> show({
    required BuildContext context,
    required RecoverySession session,
    required VoidCallback onRecover,
    required VoidCallback onDiscard,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => RecoveryDialog(
        session: session,
        onRecover: onRecover,
        onDiscard: onDiscard,
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}s';
  }

  String _formatDateTime(BuildContext context, DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return AppLocalizations.of(context)?.justNow ?? 'Just now';
    } else if (difference.inHours < 1) {
      final minutes = difference.inMinutes;
      return '$minutes ${minutes == 1 ? "min" : "mins"} ago';
    } else if (difference.inDays < 1) {
      final hours = difference.inHours;
      return '$hours ${hours == 1 ? "hour" : "hours"} ago';
    } else {
      return dateTimeFormat('MMM dd, HH:mm', dateTime);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.restore,
              color: Colors.orange,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n?.recoveryDialogTitle ?? 'Interrupted Recording Found',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n?.recoveryDialogDescription ??
                'A recording was interrupted. Would you like to recover it?',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _buildInfoRow(
                  Icons.access_time,
                  l10n?.recoveryDialogRecordedAt ?? 'Recorded at',
                  _formatDateTime(context, session.startedAt),
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  Icons.timer,
                  l10n?.recoveryDialogDuration ?? 'Duration',
                  _formatDuration(session.estimatedDuration),
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  Icons.chat_bubble_outline,
                  l10n?.recoveryDialogSegments ?? 'Segments',
                  session.segmentCount.toString(),
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  Icons.text_fields,
                  l10n?.recoveryDialogWords ?? 'Words',
                  session.wordCount.toString(),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            onDiscard();
          },
          child: Text(
            l10n?.recoveryDialogDiscard ?? 'Discard',
            style: const TextStyle(
              color: Colors.grey,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pop();
            onRecover();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF485DF4),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            l10n?.recoveryDialogRecover ?? 'Recover',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(
          icon,
          color: Colors.white54,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 13,
            ),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
