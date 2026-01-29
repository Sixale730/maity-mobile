import 'package:flutter/foundation.dart';
import 'package:omi/models/daily_communication_report.dart';
import 'package:omi/services/daily_report_service.dart';
import 'package:omi/services/supabase_auth_service.dart';

class DailyReportProvider extends ChangeNotifier {
  DailyCommunicationReport? _latestReport;
  List<DailyCommunicationReport> _history = [];
  bool _isLoading = false;
  String? _error;

  DailyCommunicationReport? get latestReport => _latestReport;
  List<DailyCommunicationReport> get history => _history;
  bool get isLoading => _isLoading;
  String? get error => _error;

  bool get hasNewReport => _latestReport != null && _latestReport!.isToday;

  Future<void> fetchLatestReport() async {
    final userId = SupabaseAuthService.instance.maityUserId;
    if (userId == null) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _latestReport = await DailyReportService.getLatestReport(userId);
    } catch (e) {
      _error = e.toString();
      debugPrint('[DailyReportProvider] Error fetching latest report: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> fetchHistory({int limit = 7}) async {
    final userId = SupabaseAuthService.instance.maityUserId;
    if (userId == null) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _history = await DailyReportService.getReportHistory(userId, limit: limit);
    } catch (e) {
      _error = e.toString();
      debugPrint('[DailyReportProvider] Error fetching history: $e');
    }

    _isLoading = false;
    notifyListeners();
  }
}
