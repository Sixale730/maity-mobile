import 'package:flutter/material.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/daily_report_provider.dart';
import 'package:omi/providers/dashboard_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/conversations/widgets/processing_capture.dart';
import 'widgets/daily_score_card.dart';
import 'widgets/dashboard_header.dart';
import 'widgets/pending_tasks_preview.dart';
import 'widgets/quick_actions_row.dart';
import 'widgets/quick_record_widget.dart';
import 'widgets/quick_stats_row.dart';
import 'widgets/recent_conversations_preview.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => DashboardPageState();
}

class DashboardPageState extends State<DashboardPage> {
  final ScrollController _scrollController = ScrollController();

  void scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  void initState() {
    super.initState();
    MixpanelManager().pageOpened('Dashboard');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initDashboard();
    });
  }

  void _initDashboard() {
    if (!mounted) return;
    final dashboardProvider = context.read<DashboardProvider>();
    dashboardProvider.updateProviders(
      context.read<DailyReportProvider>(),
      context.read<UsageProvider>(),
      context.read<ActionItemsProvider>(),
    );
    dashboardProvider.refresh();
  }

  Future<void> _onRefresh() async {
    final dashboardProvider = context.read<DashboardProvider>();
    dashboardProvider.updateProviders(
      context.read<DailyReportProvider>(),
      context.read<UsageProvider>(),
      context.read<ActionItemsProvider>(),
    );
    await dashboardProvider.refresh();
    if (mounted) {
      await context.read<ConversationProvider>().refreshConversations();
      if (mounted) {
        await context.read<ActionItemsProvider>().forceRefreshActionItems();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: const Color(0xFF485DF4),
      child: ListView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          const DashboardHeader(),
          const ConversationCaptureWidget(),
          const QuickRecordWidget(),
          DailyScoreCard(
            onTap: () {
              // Navigate to Insights tab (nav index 4)
              context.read<HomeProvider>().setIndex(4);
            },
          ),
          const QuickStatsRow(),
          const QuickActionsRow(),
          const SizedBox(height: 4),
          const RecentConversationsPreview(),
          const PendingTasksPreview(),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}
