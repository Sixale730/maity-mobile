import 'package:omi/backend/preferences.dart';

/// Lightweight utility that captures a snapshot of the app state at crash time.
///
/// Uses only singletons and SharedPreferencesUtil — no Provider dependency.
/// Every accessor is wrapped in try-catch so this never throws.
class AppStateCollector {
  AppStateCollector._();

  /// Static flag updated by AppLifecycleManager when app goes to background.
  static bool isInBackground = false;

  /// Static flag updated by CaptureProvider when recording state changes.
  static bool isRecording = false;

  /// Capture a snapshot of current app state. Never throws.
  static Map<String, dynamic> snapshot() {
    final state = <String, dynamic>{};

    try {
      state['recording'] = isRecording;
    } catch (_) {}

    try {
      final device = SharedPreferencesUtil().btDevice;
      state['device_connected'] = device.id.isNotEmpty;
    } catch (_) {}

    try {
      state['stt_provider'] = SharedPreferencesUtil().customSttConfig.provider.name;
    } catch (_) {}

    try {
      state['is_background'] = isInBackground;
    } catch (_) {}

    return state;
  }
}
