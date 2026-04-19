import 'package:flutter/foundation.dart';
import 'package:omi/utils/crash_log_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Product-analytics logger that fires events to `maity.platform_logs` via
/// the `public.insert_platform_log` RPC.
///
/// Fire-and-forget: never throws. The RPC is `SECURITY DEFINER` with
/// `EXCEPTION WHEN OTHERS THEN NULL`, and we wrap the call in try/catch —
/// so failures are invisible to callers and never affect UX.
///
/// Session context (`session_id`, `app_version`, `device_info`) is reused
/// from [CrashLogManager] so events emitted here correlate with crashes
/// emitted during the same app launch.
///
/// Complementary to Mixpanel: Mixpanel captures behavioral events with a
/// hosted analytics UI; `platform_logs` stores raw events in Supabase for
/// SQL joins against `omi_conversations`, `recording_session_telemetry`,
/// etc., and feeds the internal admin dashboard.
class PlatformLogger {
  PlatformLogger._internal();
  static final PlatformLogger instance = PlatformLogger._internal();

  bool _initialized = false;

  /// Wait for [CrashLogManager.init] to have run before calling this, so the
  /// session/device context is populated. Safe to call multiple times.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    debugPrint(
        '[PlatformLogger] init session=${CrashLogManager.instance.sessionId} '
        'version=${CrashLogManager.instance.appVersion}');
  }

  /// Session ID stable per app launch (same as [CrashLogManager.sessionId]).
  String get sessionId => CrashLogManager.instance.sessionId;

  /// Emit a product event. Does not await the network call — caller can
  /// continue immediately. Silently skips if user is unauthenticated.
  ///
  /// * [eventType] — dotted namespace (e.g. `app.open`, `nav.page_view`,
  ///   `recording.started`). Match the convention used by web/desktop.
  /// * [data] — JSONB payload. Keep keys stable (they're consumed by SQL).
  /// * [status] / [error] — optional free-form fields (mirror crash schema).
  /// * [meetingId] — correlate with a specific conversation when relevant.
  void logEvent(
    String eventType, {
    Map<String, dynamic>? data,
    String? status,
    String? error,
    String? meetingId,
  }) {
    // Unawaited on purpose — fire-and-forget.
    _send(
      eventType: eventType,
      data: data,
      status: status,
      error: error,
      meetingId: meetingId,
    );
  }

  Future<void> _send({
    required String eventType,
    Map<String, dynamic>? data,
    String? status,
    String? error,
    String? meetingId,
  }) async {
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser == null) return;

      final crash = CrashLogManager.instance;
      final platform = _mapPlatform(crash.platform);

      await client.rpc('insert_platform_log', params: {
        'p_session_id': crash.sessionId,
        'p_platform': platform,
        'p_event_type': eventType,
        'p_event_data': data,
        'p_status': status,
        'p_error': error,
        'p_meeting_id': meetingId,
        'p_app_version': crash.appVersion,
        'p_device_info': crash.deviceInfo,
      });
    } catch (e) {
      debugPrint('[PlatformLogger] $eventType failed (ignored): $e');
    }
  }

  /// Map the OS-level platform string from [CrashLogManager] to the
  /// high-level bucket used by the admin dashboard: `mobile` | `desktop`.
  /// Keeps the `platform_logs.platform` column consistent with existing
  /// web/desktop/mobile rows.
  static String _mapPlatform(String? raw) {
    switch (raw) {
      case 'android':
      case 'ios':
        return 'mobile';
      case 'macos':
      case 'windows':
      case 'linux':
        return 'desktop';
      default:
        return 'unknown';
    }
  }
}
