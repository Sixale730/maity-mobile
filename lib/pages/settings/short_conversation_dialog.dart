import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:provider/provider.dart';

class ShortConversationDialog {
  static Future<void> show(BuildContext context) async {
    final provider = Provider.of<ConversationProvider>(context, listen: false);
    final currentThreshold = provider.shortConversationThreshold;
    int selectedThreshold = currentThreshold;
    final l10n = AppLocalizations.of(context);

    // Threshold options: 0 (show all), 30s, 60s, 120s, 300s
    final thresholdOptions = [
      {
        'label': l10n?.showAllConversations ?? 'Show all',
        'value': 0,
        'description': l10n?.showAllConversationsDesc ?? 'Display all conversations regardless of duration'
      },
      {
        'label': l10n?.nSeconds(30) ?? '30 seconds',
        'value': 30,
        'description': l10n?.hideConversationsShorterThan(30) ?? 'Hide conversations shorter than 30 seconds'
      },
      {
        'label': l10n?.nMinute(1) ?? '1 minute',
        'value': 60,
        'description': l10n?.hideConversationsShorterThan(60) ?? 'Hide conversations shorter than 1 minute'
      },
      {
        'label': l10n?.nMinutesPlural(2) ?? '2 minutes',
        'value': 120,
        'description': l10n?.hideConversationsShorterThan(120) ?? 'Hide conversations shorter than 2 minutes'
      },
      {
        'label': l10n?.nMinutesPlural(5) ?? '5 minutes',
        'value': 300,
        'description': l10n?.hideConversationsShorterThan(300) ?? 'Hide conversations shorter than 5 minutes'
      },
    ];

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(
                l10n?.shortConversationFilter ?? 'Short Conversation Filter',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n?.shortConversationFilterDescription ??
                          'Choose the minimum duration for conversations to be displayed:',
                      style: const TextStyle(
                        color: Color(0xFF8E8E93),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...thresholdOptions.map((option) {
                      final isSelected = selectedThreshold == option['value'];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              setState(() {
                                selectedThreshold = option['value'] as int;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected ? Colors.white : const Color(0xFF3C3C43),
                                  width: isSelected ? 2 : 1,
                                ),
                                color: isSelected ? const Color(0xFF2C2C2E) : Colors.transparent,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          option['label'] as String,
                                          style: TextStyle(
                                            color: isSelected ? Colors.white : const Color(0xFFE5E5E7),
                                            fontSize: 16,
                                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          option['description'] as String,
                                          style: TextStyle(
                                            color: isSelected ? const Color(0xFFAEAEB2) : const Color(0xFF8E8E93),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    const Icon(
                                      Icons.check_circle,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: Text(
                    l10n?.cancel ?? 'Cancel',
                    style: const TextStyle(color: Color(0xFF8E8E93)),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    provider.setShortConversationThreshold(selectedThreshold);
                    Navigator.of(context).pop();

                    // Show confirmation
                    String message;
                    if (selectedThreshold == 0) {
                      message = l10n?.allConversationsShown ?? 'All conversations are now shown';
                    } else {
                      final minutes = selectedThreshold ~/ 60;
                      final seconds = selectedThreshold % 60;
                      if (minutes > 0 && seconds == 0) {
                        message = l10n?.conversationsHiddenMinutes(minutes) ??
                            'Conversations shorter than $minutes minute${minutes == 1 ? '' : 's'} are now hidden';
                      } else {
                        message = l10n?.conversationsHiddenSeconds(selectedThreshold) ??
                            'Conversations shorter than $selectedThreshold seconds are now hidden';
                      }
                    }
                    AppSnackbar.showSnackbar(message);
                  },
                  child: Text(
                    l10n?.save ?? 'Save',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
