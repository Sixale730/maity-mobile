import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:omi/backend/preferences.dart';

/// Syncs Flutter recording state to native Home Screen Widgets.
///
/// Uses `home_widget` package to write state to App Group UserDefaults (iOS)
/// and SharedPreferences (Android), then triggers a widget refresh.
class WidgetStateService {
  static const _appGroupId = 'group.com.maity.app';
  static const _androidWidgetName = 'com.maity.app.MaityWidgetProvider';
  static const _iOSQuickRecordName = 'MaityQuickRecord';
  static const _iOSStatusName = 'MaityStatus';

  static Future<void> initialize() async {
    if (Platform.isIOS) {
      await HomeWidget.setAppGroupId(_appGroupId);
    }
  }

  static Future<void> syncState({
    required bool isRecording,
    required bool isPaused,
    required int segmentCount,
  }) async {
    try {
      final lang = SharedPreferencesUtil().appLanguage;
      await Future.wait([
        HomeWidget.saveWidgetData('isRecording', isRecording),
        HomeWidget.saveWidgetData('isPaused', isPaused),
        HomeWidget.saveWidgetData('segmentCount', segmentCount),
        HomeWidget.saveWidgetData('language', lang),
      ]);

      // Refresh widgets on both platforms
      if (Platform.isAndroid) {
        await HomeWidget.updateWidget(qualifiedAndroidName: _androidWidgetName);
      } else if (Platform.isIOS) {
        await HomeWidget.updateWidget(iOSName: _iOSQuickRecordName);
        await HomeWidget.updateWidget(iOSName: _iOSStatusName);
      }
    } catch (e) {
      debugPrint('[WidgetStateService] Sync error: $e');
    }
  }
}
