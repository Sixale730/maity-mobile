import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/maity_api_service.dart';

/// Service for storing and retrieving usage metrics locally
/// Tracks transcription time, words, conversations, and insights
class LocalMetricsService {
  static const String _metricsKey = 'local_metrics_v1';
  static const String _dailyMetricsKey = 'daily_metrics_v1';
  static const String _categoryCountsKey = 'category_counts_v1';

  /// Get current metrics from local storage
  static LocalMetrics getMetrics() {
    try {
      final prefs = SharedPreferencesUtil();
      final json = prefs.getString(_metricsKey);

      if (json.isEmpty) {
        return LocalMetrics.empty();
      }

      return LocalMetrics.fromJson(jsonDecode(json));
    } catch (e) {
      debugPrint('[LocalMetricsService] Error loading metrics: $e');
      return LocalMetrics.empty();
    }
  }

  /// Save metrics to local storage
  static Future<void> saveMetrics(LocalMetrics metrics) async {
    try {
      final prefs = SharedPreferencesUtil();
      await prefs.saveString(_metricsKey, jsonEncode(metrics.toJson()));
    } catch (e) {
      debugPrint('[LocalMetricsService] Error saving metrics: $e');
    }
  }

  /// Record a new conversation
  static Future<void> recordConversation({
    required int durationSeconds,
    required int wordsCount,
    required int insightsCount,
    required String category,
  }) async {
    final metrics = getMetrics();

    metrics.totalTranscriptionSeconds += durationSeconds;
    metrics.totalWordsTranscribed += wordsCount;
    metrics.totalConversations += 1;
    metrics.totalInsightsGained += insightsCount;

    // Update category counts
    metrics.categoryCounts[category] = (metrics.categoryCounts[category] ?? 0) + 1;

    // Update daily metrics
    final today = _getTodayKey();
    final dailyMetrics = getDailyMetrics();
    final todayMetrics = dailyMetrics[today] ?? DailyLocalMetrics.empty(today);
    todayMetrics.conversations += 1;
    todayMetrics.transcriptionSeconds += durationSeconds;
    todayMetrics.wordsTranscribed += wordsCount;
    dailyMetrics[today] = todayMetrics;

    await saveMetrics(metrics);
    await _saveDailyMetrics(dailyMetrics);

    debugPrint('[LocalMetricsService] Recorded conversation: ${metrics.totalConversations} total');
  }

  /// Get daily metrics map
  static Map<String, DailyLocalMetrics> getDailyMetrics() {
    try {
      final prefs = SharedPreferencesUtil();
      final json = prefs.getString(_dailyMetricsKey);

      if (json.isEmpty) {
        return {};
      }

      final Map<String, dynamic> data = jsonDecode(json);
      return data.map((key, value) => MapEntry(key, DailyLocalMetrics.fromJson(value)));
    } catch (e) {
      debugPrint('[LocalMetricsService] Error loading daily metrics: $e');
      return {};
    }
  }

  /// Save daily metrics
  static Future<void> _saveDailyMetrics(Map<String, DailyLocalMetrics> dailyMetrics) async {
    try {
      final prefs = SharedPreferencesUtil();
      final data = dailyMetrics.map((key, value) => MapEntry(key, value.toJson()));
      await prefs.saveString(_dailyMetricsKey, jsonEncode(data));
    } catch (e) {
      debugPrint('[LocalMetricsService] Error saving daily metrics: $e');
    }
  }

  /// Get metrics for today
  static DailyLocalMetrics getTodayMetrics() {
    final daily = getDailyMetrics();
    final today = _getTodayKey();
    return daily[today] ?? DailyLocalMetrics.empty(today);
  }

  /// Get metrics for the last N days
  static List<DailyLocalMetrics> getRecentDailyMetrics(int days) {
    final daily = getDailyMetrics();
    final now = DateTime.now();
    final result = <DailyLocalMetrics>[];

    for (int i = 0; i < days; i++) {
      final date = now.subtract(Duration(days: i));
      final key = _getDateKey(date);
      result.add(daily[key] ?? DailyLocalMetrics.empty(key));
    }

    return result;
  }

  /// Get top categories sorted by count
  static List<CategoryCountLocal> getTopCategories({int limit = 10}) {
    final metrics = getMetrics();
    final sorted = metrics.categoryCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted
        .take(limit)
        .map((e) => CategoryCountLocal(category: e.key, count: e.value))
        .toList();
  }

  /// Get metrics summary (local data)
  static MetricsSummaryLocal getSummary() {
    final total = getMetrics();
    final today = getTodayMetrics();
    final last30Days = getRecentDailyMetrics(30);

    // Calculate monthly totals
    int monthlyConversations = 0;
    int monthlySeconds = 0;
    int monthlyWords = 0;

    for (final day in last30Days) {
      monthlyConversations += day.conversations;
      monthlySeconds += day.transcriptionSeconds;
      monthlyWords += day.wordsTranscribed;
    }

    return MetricsSummaryLocal(
      today: PeriodMetricsLocal(
        conversations: today.conversations,
        minutes: today.transcriptionSeconds / 60,
        words: today.wordsTranscribed,
      ),
      monthly: PeriodMetricsLocal(
        conversations: monthlyConversations,
        minutes: monthlySeconds / 60,
        words: monthlyWords,
      ),
      allTime: AllTimeMetricsLocal(
        conversations: total.totalConversations,
        minutes: total.totalTranscriptionSeconds / 60,
        words: total.totalWordsTranscribed,
        insights: total.totalInsightsGained,
        topCategories: getTopCategories(limit: 5),
      ),
    );
  }

  /// Try to sync with backend and merge data
  static Future<MetricsSummary?> syncWithBackend(String userId) async {
    try {
      final backendSummary = await MaityApiService.getMetricsSummary(userId);
      if (backendSummary != null) {
        debugPrint('[LocalMetricsService] Synced with backend');
        return backendSummary;
      }
    } catch (e) {
      debugPrint('[LocalMetricsService] Backend sync failed: $e');
    }
    return null;
  }

  /// Clear all local metrics
  static Future<void> clearAll() async {
    final prefs = SharedPreferencesUtil();
    await prefs.saveString(_metricsKey, '');
    await prefs.saveString(_dailyMetricsKey, '');
    debugPrint('[LocalMetricsService] Cleared all metrics');
  }

  static String _getTodayKey() {
    return _getDateKey(DateTime.now());
  }

  static String _getDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

/// Local metrics model
class LocalMetrics {
  int totalTranscriptionSeconds;
  int totalWordsTranscribed;
  int totalConversations;
  int totalInsightsGained;
  Map<String, int> categoryCounts;

  LocalMetrics({
    required this.totalTranscriptionSeconds,
    required this.totalWordsTranscribed,
    required this.totalConversations,
    required this.totalInsightsGained,
    required this.categoryCounts,
  });

  factory LocalMetrics.empty() {
    return LocalMetrics(
      totalTranscriptionSeconds: 0,
      totalWordsTranscribed: 0,
      totalConversations: 0,
      totalInsightsGained: 0,
      categoryCounts: {},
    );
  }

  factory LocalMetrics.fromJson(Map<String, dynamic> json) {
    return LocalMetrics(
      totalTranscriptionSeconds: json['total_transcription_seconds'] ?? 0,
      totalWordsTranscribed: json['total_words_transcribed'] ?? 0,
      totalConversations: json['total_conversations'] ?? 0,
      totalInsightsGained: json['total_insights_gained'] ?? 0,
      categoryCounts: Map<String, int>.from(json['category_counts'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'total_transcription_seconds': totalTranscriptionSeconds,
      'total_words_transcribed': totalWordsTranscribed,
      'total_conversations': totalConversations,
      'total_insights_gained': totalInsightsGained,
      'category_counts': categoryCounts,
    };
  }
}

/// Daily metrics model
class DailyLocalMetrics {
  String date;
  int conversations;
  int transcriptionSeconds;
  int wordsTranscribed;

  DailyLocalMetrics({
    required this.date,
    required this.conversations,
    required this.transcriptionSeconds,
    required this.wordsTranscribed,
  });

  factory DailyLocalMetrics.empty(String date) {
    return DailyLocalMetrics(
      date: date,
      conversations: 0,
      transcriptionSeconds: 0,
      wordsTranscribed: 0,
    );
  }

  factory DailyLocalMetrics.fromJson(Map<String, dynamic> json) {
    return DailyLocalMetrics(
      date: json['date'] ?? '',
      conversations: json['conversations'] ?? 0,
      transcriptionSeconds: json['transcription_seconds'] ?? 0,
      wordsTranscribed: json['words_transcribed'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'date': date,
      'conversations': conversations,
      'transcription_seconds': transcriptionSeconds,
      'words_transcribed': wordsTranscribed,
    };
  }

  double get minutes => transcriptionSeconds / 60;
}

/// Category count model
class CategoryCountLocal {
  final String category;
  final int count;

  CategoryCountLocal({required this.category, required this.count});
}

/// Period metrics (local)
class PeriodMetricsLocal {
  final int conversations;
  final double minutes;
  final int words;

  PeriodMetricsLocal({
    required this.conversations,
    required this.minutes,
    required this.words,
  });
}

/// All-time metrics (local)
class AllTimeMetricsLocal extends PeriodMetricsLocal {
  final int insights;
  final List<CategoryCountLocal> topCategories;

  AllTimeMetricsLocal({
    required super.conversations,
    required super.minutes,
    required super.words,
    required this.insights,
    required this.topCategories,
  });
}

/// Metrics summary (local)
class MetricsSummaryLocal {
  final PeriodMetricsLocal today;
  final PeriodMetricsLocal monthly;
  final AllTimeMetricsLocal allTime;

  MetricsSummaryLocal({
    required this.today,
    required this.monthly,
    required this.allTime,
  });
}
