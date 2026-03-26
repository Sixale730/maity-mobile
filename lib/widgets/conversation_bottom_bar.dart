import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/schema/app.dart';
import 'package:omi/gen/assets.gen.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/widgets/conversation_bottom_bar/tab_button.dart';
import 'package:provider/provider.dart';

enum ConversationBottomBarMode {
  recording, // During active recording (no summary icon)
  detail // For viewing completed conversations
}

enum ConversationTab { transcript, summary, actionItems }

class ConversationBottomBar extends StatelessWidget {
  final ConversationBottomBarMode mode;
  final ConversationTab selectedTab;
  final Function(ConversationTab) onTabSelected;
  final VoidCallback onStopPressed;
  final bool hasSegments;
  final bool hasActionItems;

  const ConversationBottomBar({
    super.key,
    required this.mode,
    required this.selectedTab,
    required this.onTabSelected,
    required this.onStopPressed,
    this.hasSegments = true,
    this.hasActionItems = true,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      heightFactor: 1.0,
      child: _buildBottomBar(context),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Material(
        elevation: 8,
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: mode == ConversationBottomBarMode.recording ? 180 : null,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF1A0B2E), // Very deep purple
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                spreadRadius: 1,
                blurRadius: 5,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Transcript tab
              _buildTranscriptTab(),

              // Add minimal spacing between tabs
              const SizedBox(width: 4),

              // Stop button or Summary/Action Items tabs
              ...switch (mode) {
                ConversationBottomBarMode.recording => [_buildStopButton()],
                ConversationBottomBarMode.detail => [
                    _buildSummaryTab(context),
                    if (hasActionItems) ...[
                      const SizedBox(width: 4),
                      _buildActionItemsTab(),
                    ],
                  ],
              },
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTranscriptTab() {
    return TabButton(
      icon: FontAwesomeIcons.solidComments,
      isSelected: selectedTab == ConversationTab.transcript,
      onTap: hasSegments ? () => onTabSelected(ConversationTab.transcript) : null,
    );
  }

  Widget _buildStopButton() {
    return Container(
      height: 40,
      width: 40,
      decoration: BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.red.withValues(alpha: 0.4),
            spreadRadius: 1,
            blurRadius: 4,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onStopPressed,
          child: const Icon(
            Icons.stop_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryTab(BuildContext context) {
    return Consumer<ConversationDetailProvider>(
      builder: (context, provider, _) {
        final summarizedApp = provider.getSummarizedApp();
        final app = summarizedApp != null
            ? provider.appsList.firstWhereOrNull((element) => element.id == summarizedApp.appId)
            : null;

        return _buildSummaryTabContent(context, provider, app);
      },
    );
  }

  Widget _buildSummaryTabContent(BuildContext context, ConversationDetailProvider provider, App? app) {
    return Consumer<ConversationDetailProvider>(
      builder: (context, detailProvider, _) {
        final isReprocessing = detailProvider.loadingReprocessConversation;
        final reprocessingApp = detailProvider.selectedAppForReprocessing;

        return TabButton(
          icon: null,
          customIcon: app == null && reprocessingApp == null
              ? SvgPicture.asset(
                  Assets.images.aiMagic,
                  color: Colors.white,
                )
              : null,
          isSelected: selectedTab == ConversationTab.summary,
          onTap: () => onTabSelected(ConversationTab.summary),
          label: null,
          appImage: isReprocessing
              ? (reprocessingApp != null ? reprocessingApp.getImageUrl() : Assets.images.herologo.path)
              : (app?.getImageUrl()),
          isLocalAsset: isReprocessing && reprocessingApp == null,
          showDropdownArrow: false,
          isLoading: isReprocessing,
        );
      },
    );
  }

  Widget _buildActionItemsTab() {
    return TabButton(
      icon: FontAwesomeIcons.listCheck,
      isSelected: selectedTab == ConversationTab.actionItems,
      onTap: () => onTabSelected(ConversationTab.actionItems),
    );
  }
}
