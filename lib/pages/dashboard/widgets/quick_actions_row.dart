import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/chat/page.dart';
import 'package:omi/pages/conversation_capturing/page.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/enums.dart';
import 'package:provider/provider.dart';

class QuickActionsRow extends StatelessWidget {
  const QuickActionsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.quickActions, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade400)),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildActionButton(
                context,
                icon: FontAwesomeIcons.microphone,
                label: l10n.record,
                color: const Color(0xFF485DF4),
                onTap: () => _handleRecord(context),
              ),
              const SizedBox(width: 12),
              _buildActionButton(
                context,
                icon: FontAwesomeIcons.chartColumn,
                label: l10n.viewReport,
                color: Colors.cyan,
                onTap: () {
                  // Navigate to Insights tab (index 4 in nav)
                  context.read<HomeProvider>().setIndex(4);
                },
              ),
              const SizedBox(width: 12),
              _buildActionButton(
                context,
                icon: FontAwesomeIcons.solidComment,
                label: l10n.chat,
                color: Colors.pink,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ChatPage(isPivotBottom: false)),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Column(
            children: [
              FaIcon(icon, size: 18, color: color),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleRecord(BuildContext context) async {
    final captureProvider = context.read<CaptureProvider>();
    final recordingState = captureProvider.recordingState;

    if (recordingState == RecordingState.record) {
      await captureProvider.stopStreamRecording();
      captureProvider.forceProcessingCurrentConversation();
      MixpanelManager().phoneMicRecordingStopped();
    } else if (recordingState == RecordingState.initialising) {
      return;
    } else {
      await captureProvider.streamRecording();
      MixpanelManager().phoneMicRecordingStarted();

      if (context.mounted) {
        var topConvoId = (captureProvider.conversationProvider?.conversations ?? []).isNotEmpty
            ? captureProvider.conversationProvider!.conversations.first.id
            : null;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ConversationCapturingPage(topConversationId: topConvoId),
          ),
        );
      }
    }
  }
}
