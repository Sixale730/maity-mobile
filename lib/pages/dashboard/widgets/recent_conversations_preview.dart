import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/conversation_detail/page.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:provider/provider.dart';

class RecentConversationsPreview extends StatelessWidget {
  const RecentConversationsPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<ConversationProvider>(
      builder: (context, provider, _) {
        final conversations = provider.conversations.take(3).toList();

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.recentConversations, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade400)),
                  if (conversations.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        context.read<HomeProvider>().setIndex(1);
                      },
                      child: Text(l10n.viewAll, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF485DF4))),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (conversations.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F1F25),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    children: [
                      Icon(FontAwesomeIcons.solidMessage, color: Colors.grey.shade700, size: 24),
                      const SizedBox(height: 8),
                      Text(l10n.noRecentConversations, style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                    ],
                  ),
                )
              else
                ...conversations.map((convo) => _buildConversationItem(context, convo)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildConversationItem(BuildContext context, ServerConversation convo) {
    final title = convo.structured.title.isNotEmpty ? convo.structured.title : 'Untitled';
    final overview = convo.structured.overview;
    final emoji = convo.structured.emoji;
    final timeAgo = dateTimeFormat('HH:mm', convo.createdAt);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ConversationDetailPage(conversation: convo),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F25),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            if (emoji.isNotEmpty) ...[
              Text(emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(overview, style: TextStyle(fontSize: 12, color: Colors.grey.shade500), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(timeAgo, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
