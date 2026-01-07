import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:omi/utils/debugging/crash_reporter.dart';

/// Simple logger-based crash reporter (Firebase Crashlytics removed)
class CrashlyticsManager implements CrashReporter {
  static final CrashlyticsManager _instance = CrashlyticsManager._internal();
  static CrashlyticsManager get instance => _instance;

  CrashlyticsManager._internal();

  factory CrashlyticsManager() {
    return _instance;
  }

  static Future<void> init() async {
    // No-op: Firebase Crashlytics removed
    debugPrint('[CrashlyticsManager] Initialized (logging only)');
  }

  @override
  void identifyUser(String email, String name, String userId) {
    debugPrint('[CrashlyticsManager] User identified: $userId');
  }

  @override
  void logInfo(String message) {
    debugPrint('[INFO] $message');
  }

  @override
  void logError(String message) {
    debugPrint('[ERROR] $message');
  }

  @override
  void logWarn(String message) {
    debugPrint('[WARN] $message');
  }

  @override
  void logDebug(String message) {
    debugPrint('[DEBUG] $message');
  }

  @override
  void logVerbose(String message) {
    debugPrint('[VERBOSE] $message');
  }

  @override
  void setUserAttribute(String key, String value) {
    debugPrint('[CrashlyticsManager] User attribute: $key = $value');
  }

  @override
  void setEnabled(bool isEnabled) {
    debugPrint('[CrashlyticsManager] Enabled: $isEnabled');
  }

  @override
  Future<void> reportCrash(Object exception, StackTrace stackTrace, {Map<String, String>? userAttributes}) async {
    debugPrint('[CRASH] Exception: $exception');
    debugPrint('[CRASH] StackTrace: $stackTrace');
    if (userAttributes != null) {
      debugPrint('[CRASH] Attributes: $userAttributes');
    }
  }

  @override
  NavigatorObserver? getNavigatorObserver() {
    return null;
  }

  @override
  bool get isSupported => true;
}
