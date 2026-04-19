import 'package:flutter/foundation.dart';
import 'package:omi/services/platform_logger.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Sends a single recording-session telemetry record to Supabase via the
/// `insert_recording_telemetry` RPC.
///
/// Fire-and-forget: never throws. The Supabase function uses
/// `EXCEPTION WHEN OTHERS THEN NULL` so insertion failures are silent.
class TelemetrySender {
  TelemetrySender._();

  /// Send a telemetry snapshot. Outcome is one of:
  ///   - 'completed'   — upload succeeded
  ///   - 'failed'      — upload permanently failed
  ///   - 'recovered'   — recovered from interrupted session
  ///   - 'discarded'   — user cancelled or banal
  static Future<void> send({
    required Map<String, dynamic> snapshot,
    required String outcome,
    String? conversationId,
    int uploadRetries = 0,
    int? uploadLatencyMs,
  }) async {
    try {
      final client = Supabase.instance.client;
      // Skip if user is not authenticated — RPC requires auth.uid()
      if (client.auth.currentUser == null) {
        debugPrint('[TelemetrySender] No auth session, skipping send');
        return;
      }

      final platform = (snapshot['platform'] as String?) ?? 'unknown';
      final params = <String, dynamic>{
        'p_conversation_id': conversationId,
        'p_duration_seconds': snapshot['duration_seconds'],
        'p_segments_count': snapshot['segments_count'],
        'p_words_count': snapshot['words_count'],
        'p_audio_source': snapshot['audio_source'],
        'p_device_model': snapshot['device_model'],
        'p_stt_provider': snapshot['stt_provider'],
        'p_outcome': outcome,
        'p_reconnection_count': snapshot['reconnection_count'] ?? 0,
        'p_audio_gaps_seconds': snapshot['audio_gaps_seconds'] ?? 0,
        'p_ble_disconnects': snapshot['ble_disconnects'] ?? 0,
        'p_upload_retries': uploadRetries,
        'p_upload_latency_ms': uploadLatencyMs,
        'p_avg_transcription_latency_ms':
            snapshot['avg_transcription_latency_ms'],
        'p_vad_speech_ratio': snapshot['vad_speech_ratio'],
        'p_segments_per_minute': snapshot['segments_per_minute'],
        'p_errors_count': snapshot['errors_count'] ?? 0,
        'p_app_version': snapshot['app_version'],
        'p_os_version': snapshot['os_version'],
        'p_platform': platform,
        'p_battery_start': null,
        'p_battery_end': null,
        'p_raw_metrics': snapshot['raw_metrics'],
      };

      await client.rpc('insert_recording_telemetry', params: params);
      debugPrint(
          '[TelemetrySender] Sent: outcome=$outcome session=${snapshot['session_id']} '
          'duration=${snapshot['duration_seconds']}s segments=${snapshot['segments_count']}');
    } catch (e) {
      debugPrint('[TelemetrySender] Send failed (ignored): $e');
    }

    // Mirror the event to platform_logs so the product-analytics dashboard
    // can see recording duration/outcome without joining into the technical
    // recording_session_telemetry table. Fire-and-forget; never throws.
    PlatformLogger.instance.logEvent('recording.stopped', data: {
      'recording_session_id': snapshot['session_id'],
      'duration_seconds': snapshot['duration_seconds'],
      'segments_count': snapshot['segments_count'],
      'words_count': snapshot['words_count'],
      'audio_source': snapshot['audio_source'],
      'stt_provider': snapshot['stt_provider'],
      'outcome': outcome,
    }, meetingId: conversationId);
  }
}
