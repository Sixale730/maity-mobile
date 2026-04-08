import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/pages/capture/widgets/widgets.dart';
import 'package:omi/pages/conversation_detail/page.dart';
import 'package:omi/pages/conversations/widgets/processing_capture.dart';
import 'package:omi/pages/conversations/widgets/search_result_header_widget.dart';
import 'package:omi/pages/conversations/widgets/category_filter_bar.dart';
import 'package:omi/pages/conversations/widgets/search_widget.dart';
import 'package:omi/pages/conversations/widgets/semantic_search_result_card.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/services/app_review_service.dart';
import 'package:omi/services/local_conversations_service.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/ui_guidelines.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'widgets/empty_conversations.dart';
import 'widgets/conversations_group_widget.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({super.key});

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> with AutomaticKeepAliveClientMixin {
  TextEditingController textController = TextEditingController();
  final AppReviewService _appReviewService = AppReviewService();
  final ScrollController _scrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final conversationProvider = Provider.of<ConversationProvider>(context, listen: false);
      if (conversationProvider.conversations.isEmpty) {
        await conversationProvider.getInitialConversations();
      }

      // Check if we should show the app review prompt for first conversation
      if (mounted && conversationProvider.conversations.isNotEmpty) {
        await _appReviewService.showReviewPromptIfNeeded(context, isProcessingFirstConversation: true);
      }
    });
    super.initState();
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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildConversationShimmer() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date header shimmer
          Shimmer.fromColors(
            baseColor: AppStyles.backgroundSecondary,
            highlightColor: AppStyles.backgroundTertiary,
            child: Container(
              width: 100,
              height: 16,
              decoration: BoxDecoration(
                color: AppStyles.backgroundSecondary,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Conversation items shimmer
          ...List.generate(
              3,
              (index) => Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: Shimmer.fromColors(
                      baseColor: AppStyles.backgroundSecondary,
                      highlightColor: AppStyles.backgroundTertiary,
                      child: Container(
                        height: 80,
                        decoration: BoxDecoration(
                          color: AppStyles.backgroundSecondary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  )),
        ],
      ),
    );
  }

  Widget _buildLoadingShimmer() {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _buildConversationShimmer(),
        childCount: 3, // Show 3 shimmer conversation groups
      ),
    );
  }

  Widget _buildLoadMoreShimmer() {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: Shimmer.fromColors(
        baseColor: AppStyles.backgroundSecondary,
        highlightColor: AppStyles.backgroundTertiary,
        child: Container(
          height: 60,
          margin: const EdgeInsets.symmetric(horizontal: 16.0),
          decoration: BoxDecoration(
            color: AppStyles.backgroundSecondary,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('building conversations page');
    super.build(context);
    return Consumer<ConversationProvider>(builder: (context, convoProvider, child) {
      return RefreshIndicator(
        onRefresh: () async {
          HapticFeedback.mediumImpact();
          await convoProvider.getInitialConversations();
          return;
        },
        color: const Color(0xFF485DF4),
        backgroundColor: Colors.white,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // const SliverToBoxAdapter(child: SizedBox(height: 16)), // above capture widget
            const SliverToBoxAdapter(child: SpeechProfileCardWidget()),
            const SliverToBoxAdapter(child: UpdateFirmwareCardWidget()),
            const SliverToBoxAdapter(child: SizedBox(height: 12)), // above search widget
            const SliverToBoxAdapter(child: SearchWidget()),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            const SliverToBoxAdapter(child: CategoryFilterBar()),
            const SliverToBoxAdapter(child: SizedBox(height: 0)), //below search widget
            // New conversation button
            SliverToBoxAdapter(
              child: Consumer<CaptureProvider>(
                builder: (context, captureProvider, _) {
                  final isRecording = captureProvider.recordingState == RecordingState.record ||
                      captureProvider.recordingState == RecordingState.initialising ||
                      captureProvider.recordingState == RecordingState.pause ||
                      captureProvider.recordingState == RecordingState.processing;
                  if (isRecording) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: GestureDetector(
                      onTap: () async {
                        HapticFeedback.mediumImpact();
                        MixpanelManager().phoneMicRecordingStarted();
                        await captureProvider.streamRecording();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF485DF4).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF485DF4).withValues(alpha: 0.3),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.mic, color: Color(0xFF485DF4), size: 18),
                            SizedBox(width: 8),
                            Text(
                              'Nueva conversación',
                              style: TextStyle(
                                color: Color(0xFF485DF4),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SliverToBoxAdapter(child: SearchResultHeaderWidget()),
            getProcessingConversationsWidget(convoProvider.processingConversations),
            // Show semantic search results when active
            if (convoProvider.useSemanticSearch && convoProvider.semanticSearchResults.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  childCount: convoProvider.semanticSearchResults.length,
                  (context, index) {
                    final result = convoProvider.semanticSearchResults[index];
                    return SemanticSearchResultCard(
                      result: result,
                      index: index,
                      onTap: () {
                        // Navigate to conversation detail from local storage
                        final conversation = LocalConversationsService.getConversation(result.id);
                        if (conversation != null && context.mounted) {
                          routeToPage(
                            context,
                            ConversationDetailPage(conversation: conversation),
                          );
                        }
                      },
                    );
                  },
                ),
              )
            // Show empty state
            else if (convoProvider.groupedConversations.isEmpty && !convoProvider.isLoadingConversations)
              const SliverToBoxAdapter(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 32.0),
                    child: EmptyConversationsWidget(),
                  ),
                ),
              )
            // Show loading shimmer
            else if (convoProvider.groupedConversations.isEmpty && convoProvider.isLoadingConversations)
              _buildLoadingShimmer()
            // Show grouped conversations (normal mode)
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  childCount: convoProvider.groupedConversations.length + 1,
                  (context, index) {
                    if (index == convoProvider.groupedConversations.length) {
                      debugPrint('loading more conversations');
                      if (convoProvider.isLoadingConversations) {
                        return _buildLoadMoreShimmer();
                      }
                      // widget.loadMoreMemories(); // CALL this only when visible
                      return VisibilityDetector(
                        key: const Key('conversations-key'),
                        onVisibilityChanged: (visibilityInfo) {
                          var provider = Provider.of<ConversationProvider>(context, listen: false);
                          if (provider.previousQuery.isNotEmpty) {
                            if (visibilityInfo.visibleFraction > 0 &&
                                !provider.isLoadingConversations &&
                                (provider.totalSearchPages > provider.currentSearchPage)) {
                              provider.searchMoreConversations();
                            }
                          } else {
                            if (visibilityInfo.visibleFraction > 0 && !convoProvider.isLoadingConversations) {
                              convoProvider.getMoreConversationsFromServer();
                            }
                          }
                        },
                        child: const SizedBox(height: 20, width: double.maxFinite),
                      );
                    } else {
                      var date = convoProvider.groupedConversations.keys.elementAt(index);
                      List<ServerConversation> memoriesForDate = convoProvider.groupedConversations[date]!;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (index == 0) const SizedBox(height: 10),
                          ConversationsGroupWidget(
                            isFirst: index == 0,
                            conversations: memoriesForDate,
                            date: date,
                          ),
                        ],
                      );
                    }
                  },
                ),
              ),
            const SliverToBoxAdapter(
              child: SizedBox(height: 80),
            ),
          ],
        ),
      );
    });
  }
}
