import 'package:flutter/foundation.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/utils/crash_log_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Uploads pending crash logs from [CrashLogManager] to Supabase `platform_logs`
/// on app launch.
///
/// Called from `_init()` in main.dart after Supabase init and auth restore.
/// Uses direct Supabase insert (same pattern as [CaptureLogService]).
class CrashLogUploadService {
  CrashLogUploadService._internal();
  static final CrashLogUploadService instance = CrashLogUploadService._internal();

  bool _initialized = false;

  /// Check for pending crash logs and upload them to Supabase.
  ///
  /// Silently skips if: no pending logs, no auth, or upload fails.
  /// On failure, logs are preserved for the next launch attempt.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      if (!CrashLogManager.instance.hasPendingLogs()) return;

      // Need auth to upload
      final authUser = Supabase.instance.client.auth.currentUser;
      if (authUser == null) {
        debugPrint('[CrashLogUpload] No auth — skipping upload, will retry next launch');
        return;
      }

      final userId = SupabaseAuthService.instance.maityUserId;
      if (userId == null) {
        debugPrint('[CrashLogUpload] No maityUserId — skipping upload');
        return;
      }

      final entries = CrashLogManager.instance.readPendingLogs();
      if (entries.isEmpty) return;

      debugPrint('[CrashLogUpload] Uploading ${entries.length} crash log(s)...');

      // Map entries to platform_logs schema
      final batch = entries.map((entry) {
        final errorMessage = entry['error_message'] as String? ?? '';
        return <String, dynamic>{
          'user_id': userId,
          'session_id': entry['session_id'] ?? 'unknown',
          'platform': 'mobile',
          'event_type': _classifyEventType(entry['source'] as String?),
          'event_data': {
            'error_type': entry['error_type'],
            'error_message': entry['error_message'],
            if (entry['stack_trace'] != null) 'stack_trace': entry['stack_trace'],
            'source': entry['source'],
            if (entry['app_state'] != null) 'app_state': entry['app_state'],
          },
          'status': 'error',
          'error': errorMessage.length > 500 ? '${errorMessage.substring(0, 500)}...' : errorMessage,
          'app_version': entry['app_version'],
          'device_info': entry['device_info'],
          'synced_from_local': true,
          'created_at': entry['ts'],
        };
      }).toList();

      await Supabase.instance.client.schema('maity').from('platform_logs').insert(batch);

      CrashLogManager.instance.clearLogs();
      debugPrint('[CrashLogUpload] Successfully uploaded ${batch.length} crash log(s)');
    } catch (e) {
      // Silently fail — logs stay on disk for next launch
      debugPrint('[CrashLogUpload] Upload failed (will retry next launch): $e');
    }
  }

  /// Classify the event_type based on the error source.
  static String _classifyEventType(String? source) {
    switch (source) {
      case 'flutter_error':
      case 'platform_error':
      case 'zone_error':
        return 'crash';
      case 'logger_handle':
      case 'logger_error':
      case 'crash_reporter':
        return 'app_error';
      default:
        return 'app_error';
    }
  }
}
