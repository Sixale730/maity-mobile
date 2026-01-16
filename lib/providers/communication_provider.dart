import 'package:flutter/material.dart';
import 'package:omi/models/communication_feedback.dart';
import 'package:omi/services/communication_service.dart';
import 'package:omi/services/supabase_auth_service.dart';

/// Provider for communication feedback analysis
class CommunicationProvider with ChangeNotifier {
  // Feedback for different periods
  AggregatedFeedback? _todayFeedback;
  AggregatedFeedback? get todayFeedback => _todayFeedback;

  AggregatedFeedback? _monthlyFeedback;
  AggregatedFeedback? get monthlyFeedback => _monthlyFeedback;

  AggregatedFeedback? _yearlyFeedback;
  AggregatedFeedback? get yearlyFeedback => _yearlyFeedback;

  AggregatedFeedback? _allTimeFeedback;
  AggregatedFeedback? get allTimeFeedback => _allTimeFeedback;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  /// Fetch communication feedback for a specific period
  /// [period] puede ser: today, monthly, yearly, all_time
  Future<void> fetchFeedback({required String period}) async {
    if (_isLoading) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final userId = SupabaseAuthService.instance.maityUserId;
      if (userId == null || userId.isEmpty) {
        _error = 'User not authenticated';
        _isLoading = false;
        notifyListeners();
        return;
      }

      // Convert period format for API
      String apiPeriod;
      switch (period) {
        case 'today':
          apiPeriod = 'today';
          break;
        case 'monthly':
          apiPeriod = 'monthly';
          break;
        case 'yearly':
          apiPeriod = 'yearly';
          break;
        case 'all_time':
          apiPeriod = 'all';
          break;
        default:
          apiPeriod = 'monthly';
      }

      final response = await CommunicationService.getFeedback(
        userId: userId,
        period: apiPeriod,
      );

      if (response != null) {
        switch (period) {
          case 'today':
            _todayFeedback = response.feedback;
            break;
          case 'monthly':
            _monthlyFeedback = response.feedback;
            break;
          case 'yearly':
            _yearlyFeedback = response.feedback;
            break;
          case 'all_time':
            _allTimeFeedback = response.feedback;
            break;
        }
      } else {
        _error = 'Failed to load feedback';
      }
    } catch (e) {
      debugPrint('Failed to fetch communication feedback: $e');
      _error = 'Failed to load feedback';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Get feedback for a specific period (cached)
  AggregatedFeedback? getFeedbackForPeriod(String period) {
    switch (period) {
      case 'today':
        return _todayFeedback;
      case 'monthly':
        return _monthlyFeedback;
      case 'yearly':
        return _yearlyFeedback;
      case 'all_time':
        return _allTimeFeedback;
      default:
        return _monthlyFeedback;
    }
  }

  /// Check if feedback has been loaded for a period
  bool hasFeedbackForPeriod(String period) {
    return getFeedbackForPeriod(period) != null;
  }

  /// Clear all cached feedback
  void clearCache() {
    _todayFeedback = null;
    _monthlyFeedback = null;
    _yearlyFeedback = null;
    _allTimeFeedback = null;
    _error = null;
    notifyListeners();
  }
}
