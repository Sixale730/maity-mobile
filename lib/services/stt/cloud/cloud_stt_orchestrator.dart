import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart';

/// Orchestrates the Deepgram / WebSocket cloud STT transport.
///
/// This class owns every piece of state that only makes sense for cloud STT:
/// the WebSocket socket itself, reconnect buffering, timestamp offset
/// correction, WAL capture, token refresh, keep-alive, and health monitor.
/// [TranscriptionPipeline] composes one of these alongside a
/// [LocalSttEngineService]; whichever is active for the current session
/// handles transport while the pipeline focuses on segment processing.
///
/// The orchestrator talks to the pipeline **only through callbacks** — it
/// never imports the pipeline class. That keeps it independently testable
/// and re-usable if we ever want cloud STT outside of this pipeline.
///
/// The full extraction happens over several commits:
/// - **C1 (this one)**: timestamp offset + reconnect buffer state only.
/// - **C2**: socket lifecycle (connect/disconnect/sendAudio) + WAL.
/// - **C3**: token refresh + keep-alive timer.
/// - **C4**: socket health monitor + reconnect-after-resume.
/// - **C5**: cleanup, tests, remove duplicated state from pipeline.
///
/// Until migration is complete, [TranscriptionPipeline] still owns the
/// mutable state that hasn't moved yet; the orchestrator's getters/setters
/// on those subsystems are additive and pipeline-callable.
class CloudSttOrchestrator {
  CloudSttOrchestrator({
    required CaptureLogService captureLog,
    required void Function(String rawJsonSegments) onRawMessage,
    required void Function() onSocketConnected,
    required void Function(int? closeCode) onSocketClosed,
    required void Function(Object err, StackTrace trace) onSocketError,
    required void Function() onTranscriptionStalled,
    required Future<void> Function() onAutoFinalize,
    required void Function(MessageEvent event) onMessageEventReceived,
    required void Function() onNotifyListeners,
  })  : _captureLog = captureLog,
        _onRawMessage = onRawMessage,
        _onSocketConnected = onSocketConnected,
        _onSocketClosed = onSocketClosed,
        _onSocketError = onSocketError,
        _onTranscriptionStalled = onTranscriptionStalled,
        _onAutoFinalize = onAutoFinalize,
        _onMessageEventReceived = onMessageEventReceived,
        _onNotifyListeners = onNotifyListeners;

  // ---------------------------------------------------------------------------
  // Injected dependencies
  // ---------------------------------------------------------------------------
  // ignore: unused_field
  final CaptureLogService _captureLog;
  // ignore: unused_field
  final void Function(String rawJsonSegments) _onRawMessage;
  // ignore: unused_field
  final void Function() _onSocketConnected;
  // ignore: unused_field
  final void Function(int? closeCode) _onSocketClosed;
  // ignore: unused_field
  final void Function(Object err, StackTrace trace) _onSocketError;
  // ignore: unused_field
  final void Function() _onTranscriptionStalled;
  // ignore: unused_field
  final Future<void> Function() _onAutoFinalize;
  // ignore: unused_field
  final void Function(MessageEvent event) _onMessageEventReceived;
  // ignore: unused_field
  final void Function() _onNotifyListeners;

  // ---------------------------------------------------------------------------
  // Socket (owned starting C2). Exposed as getter today so the pipeline can
  // still reach into it during migration.
  // ---------------------------------------------------------------------------
  TranscriptSegmentSocketService? socket;
  SocketServiceState? get socketState => socket?.state;
  BleAudioCodec? get codec => socket?.codec;

  // ---------------------------------------------------------------------------
  // Timestamp offset (Deepgram restarts at t=0 on every reconnect)
  // ---------------------------------------------------------------------------
  Duration _cumulativeOffset = Duration.zero;
  DateTime? _recordingStartTime;

  /// Elapsed-time offset applied to new segments so they line up on the
  /// session timeline after a Deepgram reconnect (which restarts at t=0).
  Duration get cumulativeOffset => _cumulativeOffset;

  /// Wall-clock at which the current recording started. `null` between
  /// recordings; set on the first socket connect of a session.
  DateTime? get recordingStartTime => _recordingStartTime;

  /// Call from the pipeline on the first `initiateWebsocket` of a session
  /// (before connect). Idempotent — only sets the start time once per session.
  void markRecordingStartIfNeeded() {
    _recordingStartTime ??= DateTime.now();
  }

  /// Snap the current elapsed time into [cumulativeOffset]. Call right before
  /// reopening a cloud socket so any segments the new socket emits (which
  /// restart at t=0) get shifted to the correct absolute timeline position.
  void updateTimestampOffsetOnReconnect() {
    if (_recordingStartTime != null) {
      _cumulativeOffset = DateTime.now().difference(_recordingStartTime!);
      debugPrint(
          '[CloudSttOrchestrator] Updated timestamp offset: ${_cumulativeOffset.inSeconds}s');
    }
  }

  /// Clear offset state when the whole recording stops (not on reconnects).
  void resetTimestampOffset() {
    _cumulativeOffset = Duration.zero;
    _recordingStartTime = null;
  }

  // ---------------------------------------------------------------------------
  // Reconnect audio buffer
  // ---------------------------------------------------------------------------
  /// Max reconnect buffer: ~5 s of 16 kHz 16-bit mono PCM = 160 000 bytes.
  static const int _maxReconnectBufferBytes = 160000;

  final List<List<int>> _reconnectAudioBuffer = [];
  int _reconnectAudioBufferBytes = 0;
  bool _isBufferingForReconnect = false;

  /// Whether audio is currently being buffered instead of sent (active during
  /// a reconnect gap). The pipeline checks this before routing audio frames.
  bool get isBufferingForReconnect => _isBufferingForReconnect;

  /// Turn buffering on before tearing down the old socket; turn off after
  /// [drainReconnectBuffer] has replayed everything.
  void setBufferingForReconnect(bool enabled) {
    _isBufferingForReconnect = enabled;
  }

  /// Append a frame to the reconnect buffer, dropping the oldest frames if
  /// we overflow the [_maxReconnectBufferBytes] cap. Caller must have already
  /// confirmed [isBufferingForReconnect] is true.
  void bufferAudioFrame(List<int> data) {
    _reconnectAudioBuffer.add(data);
    _reconnectAudioBufferBytes += data.length;
    while (_reconnectAudioBufferBytes > _maxReconnectBufferBytes &&
        _reconnectAudioBuffer.isNotEmpty) {
      _reconnectAudioBufferBytes -= _reconnectAudioBuffer.removeAt(0).length;
    }
  }

  /// Take ownership of the buffered frames, clearing internal state. The
  /// caller replays them onto the freshly connected socket and then toggles
  /// [setBufferingForReconnect] off.
  List<List<int>> drainReconnectBuffer() {
    final frames = List<List<int>>.from(_reconnectAudioBuffer);
    _reconnectAudioBuffer.clear();
    _reconnectAudioBufferBytes = 0;
    return frames;
  }

  /// Drop any buffered audio without replaying — used when the session is
  /// fully torn down and no replay is needed.
  void clearReconnectBuffer() {
    _reconnectAudioBuffer.clear();
    _reconnectAudioBufferBytes = 0;
    _isBufferingForReconnect = false;
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  /// Cancel timers and drop owned state. Safe to call multiple times.
  /// Future commits extend this to also cancel health / keep-alive /
  /// token-refresh timers and close the socket.
  Future<void> dispose() async {
    clearReconnectBuffer();
    resetTimestampOffset();
  }
}
