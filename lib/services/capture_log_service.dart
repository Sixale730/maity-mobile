import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:omi/services/supabase_auth_service.dart';

/// Persistent debug logging service for capture/recording diagnostics.
///
/// Buffers logs in memory and batch-inserts them to Supabase every 10 seconds
/// or when 20 logs accumulate. Never blocks the recording pipeline.
class CaptureLogService {
  CaptureLogService._internal();
  static final CaptureLogService instance = CaptureLogService._internal();

  // Buffer and flush configuration
  static const int _flushInterval = 10; // seconds
  static const int _flushThreshold = 20; // logs
  static const int _maxBufferSize = 200; // hard cap

  final List<Map<String, dynamic>> _buffer = [];
  Timer? _flushTimer;
  bool _isFlushing = false;

  // Session context
  String? _sessionId;
  String? _conversationId;
  String Function()? _getRecordingState;
  int Function()? _getSegmentCount;
  String Function()? _getSocketState;

  /// Start a new logging session.
  ///
  /// [sessionId] unique ID for this recording session.
  /// [getRecordingState] callback returning current recording state name.
  /// [getSegmentCount] callback returning current segment count.
  /// [getSocketState] callback returning current socket state.
  void startSession(
    String sessionId, {
    String Function()? getRecordingState,
    int Function()? getSegmentCount,
    String Function()? getSocketState,
  }) {
    _sessionId = sessionId;
    _conversationId = null;
    _getRecordingState = getRecordingState;
    _getSegmentCount = getSegmentCount;
    _getSocketState = getSocketState;

    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(
      const Duration(seconds: _flushInterval),
      (_) => flush(),
    );

    log('recording', 'session_started', severity: 'info');
  }

  /// Update the conversation ID once a draft is created.
  void updateConversationId(String id) {
    _conversationId = id;
  }

  /// Add a log entry to the buffer. This is synchronous and non-blocking.
  ///
  /// [eventType] category: recording, socket, ble, segment, save, health, recovery, error, metrics
  /// [eventName] specific event within the category
  /// [severity] debug, info, warning, error (default: info)
  /// [details] optional JSON-serializable map with extra context
  void log(
    String eventType,
    String eventName, {
    String severity = 'info',
    Map<String, dynamic>? details,
  }) {
    if (_sessionId == null) return;

    final authId = Supabase.instance.client.auth.currentUser?.id;
    final userId = SupabaseAuthService.instance.maityUserId;
    if (authId == null || userId == null) return;

    // Enforce buffer cap to prevent OOM
    if (_buffer.length >= _maxBufferSize) {
      // Drop oldest entries
      _buffer.removeRange(0, _flushThreshold);
    }

    _buffer.add({
      'auth_id': authId,
      'user_id': userId,
      'session_id': _sessionId,
      'conversation_id': _conversationId,
      'event_type': eventType,
      'event_name': eventName,
      'severity': severity,
      'details': details ?? {},
      'client_timestamp': DateTime.now().toUtc().toIso8601String(),
      'recording_state': _getRecordingState?.call(),
      'segment_count': _getSegmentCount?.call(),
      'socket_state': _getSocketState?.call(),
    });

    // Auto-flush when threshold reached
    if (_buffer.length >= _flushThreshold) {
      flush();
    }
  }

  /// End the current session. Performs a final flush and cleans up.
  void endSession() {
    if (_sessionId == null) return;

    log('recording', 'session_ended', severity: 'info');
    flush();

    _flushTimer?.cancel();
    _flushTimer = null;
    _sessionId = null;
    _conversationId = null;
    _getRecordingState = null;
    _getSegmentCount = null;
    _getSocketState = null;
  }

  /// Flush buffered logs to Supabase. Non-blocking with full error swallowing.
  Future<void> flush() async {
    if (_buffer.isEmpty || _isFlushing) return;

    _isFlushing = true;
    final batch = List<Map<String, dynamic>>.from(_buffer);
    _buffer.clear();

    try {
      await Supabase.instance.client
          .schema('maity')
          .from('capture_debug_logs')
          .insert(batch);
    } catch (e) {
      debugPrint('[CaptureLog] Flush failed (${batch.length} logs): $e');
      // Re-add failed logs if there is room
      if (_buffer.length + batch.length <= _maxBufferSize) {
        _buffer.insertAll(0, batch);
      }
    } finally {
      _isFlushing = false;
    }
  }
}
