import 'package:flutter/foundation.dart';
import 'package:omi/models/daily_communication_report.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/daily_report_provider.dart';
import 'package:omi/providers/usage_provider.dart';

class DashboardProvider extends ChangeNotifier {
  DailyReportProvider? _dailyReportProvider;
  UsageProvider? _usageProvider;
  ActionItemsProvider? _actionItemsProvider;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  DailyCommunicationReport? get latestReport => _dailyReportProvider?.latestReport;
  bool get hasReport => latestReport != null;

  int get todayConversationsCount {
    final usage = _usageProvider?.todayUsage;
    return usage?.conversationsCreated ?? 0;
  }

  int get todayMinutesListened {
    final usage = _usageProvider?.todayUsage;
    if (usage == null) return 0;
    return (usage.transcriptionSeconds / 60).round();
  }

  int get pendingTasksCount => _actionItemsProvider?.todoItems.length ?? 0;

  void updateProviders(
    DailyReportProvider dailyReport,
    UsageProvider usage,
    ActionItemsProvider actionItems,
  ) {
    _dailyReportProvider = dailyReport;
    _usageProvider = usage;
    _actionItemsProvider = actionItems;
  }

  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();

    try {
      await Future.wait([
        _dailyReportProvider?.fetchLatestReport() ?? Future.value(),
        _usageProvider?.fetchUsageStats(period: 'today') ?? Future.value(),
      ]);
    } catch (e) {
      debugPrint('[DashboardProvider] Error refreshing: $e');
    }

    _isLoading = false;
    notifyListeners();
  }
}
