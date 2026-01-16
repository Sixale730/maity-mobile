import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

class SearchResultHeaderWidget extends StatefulWidget {
  const SearchResultHeaderWidget({super.key});

  @override
  State<SearchResultHeaderWidget> createState() => _SearchResultHeaderWidgetState();
}

class _SearchResultHeaderWidgetState extends State<SearchResultHeaderWidget> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<ConversationProvider>(builder: (context, provider, child) {
      var onSearches = provider.previousQuery.isNotEmpty;
      var isSearching = provider.isFetchingConversations;

      return Container(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: onSearches
            ? (isSearching
                ? Shimmer.fromColors(
                    baseColor: Colors.white,
                    highlightColor: Colors.grey,
                    child: Text(
                      l10n.searchingConversations,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ))
                : provider.totalSearchPages > 0
                    ? Text(
                        l10n.searchResults,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      )
                    : const SizedBox.shrink())
            : const SizedBox.shrink(),
      );
    });
  }
}
