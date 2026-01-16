import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';

class EmptyConversationsWidget extends StatefulWidget {
  const EmptyConversationsWidget({super.key});

  @override
  State<EmptyConversationsWidget> createState() => _EmptyConversationsWidgetState();
}

class _EmptyConversationsWidgetState extends State<EmptyConversationsWidget> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 120.0),
      child: Text(
        l10n.noConversations,
        style: const TextStyle(color: Colors.grey, fontSize: 16),
      ),
    );
  }
}
