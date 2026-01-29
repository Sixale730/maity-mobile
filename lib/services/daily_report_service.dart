import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/models/daily_communication_report.dart';

class DailyReportService {
  static const String _baseUrl = 'https://maity-mobile.vercel.app';

  static Future<DailyCommunicationReport?> getLatestReport(String userId) async {
    final response = await makeApiCall(
      url: '$_baseUrl/v1/daily-reports/latest?user_id=$userId',
      method: 'GET',
      headers: {},
      body: '',
    );

    if (response == null || response.statusCode != 200) {
      debugPrint('[DailyReportService] Failed to fetch latest report: ${response?.statusCode}');
      return null;
    }

    try {
      final data = jsonDecode(response.body);
      if (data['report'] == null) return null;
      return DailyCommunicationReport.fromJson(data['report'] as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[DailyReportService] Error parsing latest report: $e');
      return null;
    }
  }

  static Future<DailyCommunicationReport?> getReportByDate(String userId, String date) async {
    final response = await makeApiCall(
      url: '$_baseUrl/v1/daily-reports/by-date?user_id=$userId&date=$date',
      method: 'GET',
      headers: {},
      body: '',
    );

    if (response == null || response.statusCode != 200) {
      debugPrint('[DailyReportService] Failed to fetch report by date: ${response?.statusCode}');
      return null;
    }

    try {
      final data = jsonDecode(response.body);
      if (data['report'] == null) return null;
      return DailyCommunicationReport.fromJson(data['report'] as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[DailyReportService] Error parsing report by date: $e');
      return null;
    }
  }

  static Future<List<DailyCommunicationReport>> getReportHistory(String userId, {int limit = 7}) async {
    final response = await makeApiCall(
      url: '$_baseUrl/v1/daily-reports/history?user_id=$userId&limit=$limit',
      method: 'GET',
      headers: {},
      body: '',
    );

    if (response == null || response.statusCode != 200) {
      debugPrint('[DailyReportService] Failed to fetch history: ${response?.statusCode}');
      return [];
    }

    try {
      final data = jsonDecode(response.body);
      final reports = data['reports'] as List? ?? [];
      return reports
          .map((r) => DailyCommunicationReport.fromJson(r as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyReportService] Error parsing history: $e');
      return [];
    }
  }
}
