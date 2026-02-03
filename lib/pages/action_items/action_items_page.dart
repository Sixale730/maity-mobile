import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'widgets/action_item_tile_widget.dart';
import 'widgets/action_item_shimmer_widget.dart';
import 'widgets/action_item_form_sheet.dart';
// import 'widgets/task_integrations_banner.dart';

import 'package:omi/backend/schema/schema.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/services/app_review_service.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/ui/molecules/omi_confirm_dialog.dart';
import 'package:omi/l10n/app_localizations.dart';

class ActionItemsPage extends StatefulWidget {
  const ActionItemsPage({super.key});

  @override
  State<ActionItemsPage> createState() => _ActionItemsPageState();
}

class _ActionItemsPageState extends State<ActionItemsPage> with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  final AppReviewService _appReviewService = AppReviewService();

  // Tab state: 0 = To Do, 1 = Done, 2 = snoozed
  int _selectedTabIndex = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      MixpanelManager().actionItemsPageOpened();
      final provider = Provider.of<ActionItemsProvider>(context, listen: false);
      if (provider.actionItems.isEmpty) {
        provider.fetchActionItems(showShimmer: true);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  // checks if it's the first action item completed
  Future<void> _onActionItemCompleted({bool isSnoozed = false}) async {
    MixpanelManager().actionItemCompleted(fromTab: isSnoozed ? 'Snoozed' : 'To Do');

    final hasCompletedFirst = await _appReviewService.hasCompletedFirstActionItem();

    if (!hasCompletedFirst) {
      await _appReviewService.markFirstActionItemCompleted();

      if (mounted) {
        await _appReviewService.showReviewPromptIfNeeded(context, isProcessingFirstConversation: false);
      }
    }
  }

  void _onScroll() {
    final provider = Provider.of<ActionItemsProvider>(context, listen: false);
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!provider.isFetching && provider.hasMore) {
        provider.loadMoreActionItems();
      }
    }
  }

  void scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _showCreateActionItemSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const ActionItemFormSheet(),
    );
  }

  void _onTabChanged(int value) {
    setState(() {
      _selectedTabIndex = value;
    });
    HapticFeedback.selectionClick();

    // Track tab change
    final tabName = value == 0 ? 'To Do' : (value == 1 ? 'Done' : 'Old');
    MixpanelManager().actionItemTabChanged(tabName);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Consumer<ActionItemsProvider>(
      builder: (context, provider, child) {
        // Get categorized items based on tab
        final todoItems = provider.todoItems;
        final doneItems = provider.doneItems;
        final snoozedItems = provider.snoozedItems;

        // Get current tab items
        final currentTabItems = _selectedTabIndex == 0
            ? todoItems
            : _selectedTabIndex == 1
                ? doneItems
                : snoozedItems;

        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.primary,
          appBar: provider.isSelectionMode ? _buildSelectionAppBar(provider, currentTabItems) : null,
          floatingActionButton: provider.isSelectionMode
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: 60.0),
                  child: FloatingActionButton(
                    heroTag: 'action_items_fab',
                    onPressed: _showCreateActionItemSheet,
                    backgroundColor: const Color(0xFF485DF4),
                    child: const Icon(
                      Icons.add,
                      color: Colors.white,
                    ),
                  ),
                ),
          body: RefreshIndicator(
            onRefresh: () async {
              HapticFeedback.mediumImpact();
              return provider.forceRefreshActionItems();
            },
            color: const Color(0xFF485DF4),
            backgroundColor: Colors.white,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // Main Content
                if (provider.isLoading && provider.actionItems.isEmpty) ...[
                  // Header shimmer
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                AppLocalizations.of(context)?.toDos ?? 'To-Do\'s',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.grey[800]?.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            AppLocalizations.of(context)?.tapEditLongPressSwipe ?? 'Tap to edit • Long press to select • Swipe for actions',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Shimmer list
                  const ActionItemsShimmerList(),
                ] else if (provider.actionItems.isEmpty)
                  SliverFillRemaining(
                    child: _buildSmartEmptyState(provider),
                  )
                else
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Task Integrations Banner (disabled)
                          // const TaskIntegrationsBanner(),

                          // Segmented Control - Full width like action items
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1C1C1E),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final tabWidth = constraints.maxWidth / 3;
                                return Stack(
                                  children: [
                                    // Animated sliding background
                                    AnimatedPositioned(
                                      duration: const Duration(milliseconds: 200),
                                      curve: Curves.easeInOut,
                                      left: _selectedTabIndex * tabWidth,
                                      top: 0,
                                      bottom: 0,
                                      width: tabWidth,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2C2C2E),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                    // Tab buttons
                                    Row(
                                      children: [
                                        Expanded(
                                          child: GestureDetector(
                                            onTap: () => _onTabChanged(0),
                                            behavior: HitTestBehavior.opaque,
                                            child: _buildTabLabel(AppLocalizations.of(context)?.toDoTab ?? 'To Do', todoItems.length, 0),
                                          ),
                                        ),
                                        Expanded(
                                          child: GestureDetector(
                                            onTap: () => _onTabChanged(1),
                                            behavior: HitTestBehavior.opaque,
                                            child: _buildTabLabel(AppLocalizations.of(context)?.doneTab ?? 'Done', doneItems.length, 1),
                                          ),
                                        ),
                                        Expanded(
                                          child: GestureDetector(
                                            onTap: () => _onTabChanged(2),
                                            behavior: HitTestBehavior.opaque,
                                            child: _buildTabLabel(AppLocalizations.of(context)?.oldTab ?? 'Old', snoozedItems.length, 2),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),

                // Current Tab Items
                if (provider.actionItems.isNotEmpty && currentTabItems.isNotEmpty)
                  _buildTabItems(currentTabItems, provider)
                else if (provider.actionItems.isNotEmpty && currentTabItems.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Container(
                        height: 120,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F1F25),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Center(
                          child: Text(
                            _getEmptyTabMessage(context),
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),

                // Loading shimmer for pagination
                if (provider.isFetching || provider.isLoading)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: List.generate(
                            3,
                            (index) => const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 4),
                                  child: ActionItemShimmerWidget(),
                                )),
                      ),
                    ),
                  ),

                const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabItems(List<ActionItemWithMetadata> items, ActionItemsProvider provider) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index < items.length) {
            final item = items[index];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildDismissibleActionItem(
                item: item,
                provider: provider,
              ),
            );
          }
          return null;
        },
        childCount: items.length,
      ),
    );
  }

  String _getEmptyTabMessage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (_selectedTabIndex) {
      case 0: // To Do
        return l10n?.allCaughtUp ?? '🎉 All caught up!\nNo pending action items';
      case 1: // Done
        return l10n?.noCompletedItemsYet ?? 'No completed items yet';
      case 2: // Old
        return l10n?.noOldTasks ?? '✅ No old tasks';
      default:
        return l10n?.noItems ?? 'No items';
    }
  }

  Widget _buildDismissibleActionItem({
    required ActionItemWithMetadata item,
    required ActionItemsProvider provider,
  }) {
    return Dismissible(
      key: Key(item.id),
      // Swipe right background - Mark as completed
      background: provider.isSelectionMode
          ? null
          : Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: item.completed ? Colors.orange : Colors.green,
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: Icon(
                item.completed ? Icons.undo : Icons.check,
                color: Colors.white,
                size: 24,
              ),
            ),
      // Swipe left background - Delete
      secondaryBackground: provider.isSelectionMode
          ? null
          : Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(
                Icons.delete,
                color: Colors.white,
                size: 24,
              ),
            ),
      confirmDismiss: (direction) async {
        // Disable swipe gestures when in selection mode
        if (provider.isSelectionMode) {
          return false;
        }

        if (direction == DismissDirection.startToEnd) {
          // Swipe right - Toggle completion
          await provider.updateActionItemState(item, !item.completed);
          final l10n = AppLocalizations.of(context);

          // Show feedback
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(item.completed ? (l10n?.actionItemMarkedIncomplete ?? 'Action item marked as incomplete') : (l10n?.actionItemCompleted ?? 'Action item completed')),
                backgroundColor: item.completed ? Colors.orange : Colors.green,
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return false;
        } else {
          // Swipe left - Show delete confirmation
          await _deleteActionItem(item, provider);
          return false;
        }
      },
      onDismissed: (direction) async {
        // Only called for delete action (swipe left)
        if (direction == DismissDirection.endToStart) {
          await _deleteActionItem(item, provider);
        }
      },
      child: ActionItemTileWidget(
        actionItem: item,
        onToggle: (newState) {
          provider.updateActionItemState(item, newState);
          if (newState) {
            _onActionItemCompleted(isSnoozed: _selectedTabIndex == 2);
          }
        },
        onRefresh: () => provider.fetchActionItems(),
        isSelectionMode: provider.isSelectionMode,
        isSelected: provider.isItemSelected(item.id),
        onLongPress: () => _handleItemLongPress(item, provider),
        onSelectionToggle: () => provider.toggleItemSelection(item.id),
        isSnoozedTab: _selectedTabIndex == 2,
      ),
    );
  }

  void _handleItemLongPress(ActionItemWithMetadata item, ActionItemsProvider provider) {
    if (!provider.isSelectionMode) {
      // Enter selection mode and select the long-pressed item
      provider.startSelection();
      provider.selectItem(item.id);
      HapticFeedback.mediumImpact();
    }
  }

  PreferredSizeWidget _buildSelectionAppBar(
      ActionItemsProvider provider, List<ActionItemWithMetadata> currentTabItems) {
    return AppBar(
      backgroundColor: Colors.black.withValues(alpha: 0.05),
      elevation: 0,
      foregroundColor: Colors.white,
      leading: IconButton(
        icon: const Icon(Icons.close, size: 20),
        onPressed: () => provider.endSelection(),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
      title: Text(
        AppLocalizations.of(context)?.nSelected(provider.selectedCount) ?? '${provider.selectedCount} selected',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      actions: [
        if (provider.selectedCount < currentTabItems.length)
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.squareCheck, size: 18),
            tooltip: AppLocalizations.of(context)?.selectAll ?? 'Select all',
            onPressed: () => provider.selectAllItemsFromTab(_selectedTabIndex),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        if (provider.hasSelection)
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.trash, size: 20),
            tooltip: AppLocalizations.of(context)?.deleteSelected ?? 'Delete selected',
            onPressed: () => _deleteSelectedItems(provider),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
      ],
    );
  }

  Future<void> _deleteSelectedItems(ActionItemsProvider provider) async {
    final selectedCount = provider.selectedCount;
    if (selectedCount == 0) return;

    final prefs = SharedPreferencesUtil();

    // Check if user has opted out of delete confirmations
    if (!prefs.showActionItemDeleteConfirmation) {
      // Skip confirmation and proceed with bulk deletion
      await _performBulkDelete(provider);
      return;
    }

    // Show confirmation dialog for bulk delete
    final l10n = AppLocalizations.of(context);
    final result = await OmiConfirmDialog.showWithSkipOption(
      context,
      title: l10n?.deleteSelectedItems ?? 'Delete Selected Items',
      message: l10n?.areYouSureDeleteActionItems(selectedCount, selectedCount > 1 ? 's' : '') ?? 'Are you sure you want to delete $selectedCount selected action item${selectedCount > 1 ? 's' : ''}?',
      confirmLabel: l10n?.confirm ?? 'Confirm',
      cancelLabel: l10n?.cancel ?? 'Cancel',
      skipLabel: l10n?.doNotShowAgain ?? 'Do not show this again',
    );

    if (result != null && result.confirmed) {
      // Update preference if user chose to skip future confirmations
      if (result.skipFutureConfirmations) {
        prefs.showActionItemDeleteConfirmation = false;
      }

      await _performBulkDelete(provider);
    }
  }

  Future<void> _performBulkDelete(ActionItemsProvider provider) async {
    final selectedCount = provider.selectedCount;
    final l10n = AppLocalizations.of(context);

    try {
      final success = await provider.deleteSelectedItems();

      if (mounted && success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.actionItemsDeleted(selectedCount, selectedCount > 1 ? 's' : '') ?? '$selectedCount action item${selectedCount > 1 ? 's' : ''} deleted'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.failedToDeleteSomeItems ?? 'Failed to delete some items'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.failedToDeleteItems ?? 'Failed to delete items'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteActionItem(ActionItemWithMetadata item, ActionItemsProvider provider) async {
    final prefs = SharedPreferencesUtil();
    final l10n = AppLocalizations.of(context);

    // Check if user has opted out of delete confirmations
    if (!prefs.showActionItemDeleteConfirmation) {
      // Skip confirmation and proceed with deletion
      await _performDeleteActionItem(item, provider);
      return;
    }

    final result = await OmiConfirmDialog.showWithSkipOption(
      context,
      title: l10n?.deleteActionItem ?? 'Delete Action Item',
      message: l10n?.areYouSureDeleteActionItem ?? 'Are you sure you want to delete this action item?',
      confirmLabel: l10n?.confirm ?? 'Confirm',
      cancelLabel: l10n?.cancel ?? 'Cancel',
      skipLabel: l10n?.doNotShowAgain ?? 'Do not show this again',
    );

    if (result?.confirmed == true) {
      // Update preference if user chose to skip future confirmations
      if (result!.skipFutureConfirmations) {
        prefs.showActionItemDeleteConfirmation = false;
      }

      await _performDeleteActionItem(item, provider);
    }
  }

  Future<void> _performDeleteActionItem(ActionItemWithMetadata item, ActionItemsProvider provider) async {
    final success = await provider.deleteActionItem(item);
    final l10n = AppLocalizations.of(context);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.actionItemDeleted(item.description) ?? 'Action item "${item.description}" deleted'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n?.failedToDeleteActionItem ?? 'Failed to delete action item'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildSmartEmptyState(ActionItemsProvider provider) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(32.0),
        child: _buildFirstTimeEmptyState(),
      ),
    );
  }

  Widget _buildTabLabel(String label, int count, int tabIndex) {
    final bool isSelected = _selectedTabIndex == tabIndex;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isSelected ? Colors.white : Colors.grey[500],
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isSelected ? Colors.grey[400] : Colors.grey[600],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFirstTimeEmptyState() {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFF485DF4).withValues(alpha: 0.1),
                const Color(0xFF485DF4).withValues(alpha: 0.05),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: const Color(0xFF485DF4).withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.assignment_outlined,
                size: 40,
                color: const Color(0xFF485DF4).withValues(alpha: 0.6),
              ),
              Positioned(
                right: 24,
                bottom: 24,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 28),

        // Welcome heading
        Text(
          l10n?.readyForActionItems ?? 'Ready for Action Items',
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 16),

        // Educational description
        Text(
          l10n?.aiExtractsTasksDescription ?? 'Your AI will automatically extract tasks and to-dos from your conversations. They\'ll appear here when created.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFB0B0B0),
            fontSize: 16,
            height: 1.6,
            fontWeight: FontWeight.w400,
          ),
        ),

        const SizedBox(height: 32),

        // Subtle feature hints
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF2A2A2A),
              width: 1,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF485DF4),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n?.automaticallyExtracted ?? 'Automatically extracted from conversations',
                      style: const TextStyle(
                        color: Color(0xFFE5E5E5),
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF485DF4),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n?.tapToEditSwipe ?? 'Tap to edit, swipe to complete or delete',
                      style: const TextStyle(
                        color: Color(0xFFE5E5E5),
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF485DF4),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n?.filterByDateRanges ?? 'Filter and organize by date ranges',
                      style: const TextStyle(
                        color: Color(0xFFE5E5E5),
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
