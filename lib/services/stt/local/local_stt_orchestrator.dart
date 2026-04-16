import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/recording/ui_segment_controller.dart';
import 'package:omi/services/recording/wav_backup_service.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart'
    show IAudioTranscoder;
import 'package:omi/services/stt/local/audio_chunk_writer.dart';
import 'package:omi/services/stt/local/local_stt_engine_service.dart';

/// Orchestrates the on-device (Parakeet / Moonshine / Canary) STT transport.
///
/// Peer of [CloudSttOrchestrator] for local STT. Owns everything that only
/// makes sense when the active provider is on-device: the
/// [LocalSttEngineService] worker isolate, the chunk-writer → queue-manager
/// pipeline, the streaming fast-path kill-switch snapshot, the audio
/// transcoder (Opus → PCM16), the WAV crash-safety backup, and the bounded
/// [UISegmentController].
///
/// The orchestrator talks to [TranscriptionPipeline] **only through
/// callbacks** — it never imports the pipeline class. This keeps it
/// independently testable and symmetrical with [CloudSttOrchestrator].
///
/// The full extraction happens over several commits:
/// - **C1 (this one)**: file skeleton. Ctor + owned state fields + getters.
///   No pipeline wiring yet; this is a green-field file.
/// - **C2**: engine lifecycle (connect/disconnect, factory, warm-engine
///   injection, release-on-stop).
/// - **C3**: chunk pipeline (AudioChunkWriter, UISegmentController,
///   ChunkQueueManager wiring, streaming-health callback).
/// - **C4**: sendAudio() + flushChunkWriter().
/// - **C5**: pipeline cleanup — remove proxy state/getters from
///   [TranscriptionPipeline] once the orchestrator owns everything.
/// - **C6**: unit tests (mirror cloud_stt_orchestrator_test.dart).
class LocalSttOrchestrator {
  LocalSttOrchestrator({
    required SttProvider provider,
    required BleAudioCodec codec,
    required String sessionId,
    required bool streamingEnabled,
    required CaptureLogService captureLog,
    LocalSttEngineService? warmEngine,
    required void Function(List<TranscriptSegment> segments) onSegments,
    required void Function(bool active) onVadStateChanged,
    required void Function(Object err) onError,
    void Function(LocalSttEngineService engine)? onEngineReleased,
    required void Function() onNotifyListeners,
  })  : _provider = provider,
        _codec = codec,
        _sessionId = sessionId,
        _streamingEnabled = streamingEnabled,
        _captureLog = captureLog,
        _warmEngine = warmEngine,
        _onSegments = onSegments,
        _onVadStateChanged = onVadStateChanged,
        _onError = onError,
        _onEngineReleased = onEngineReleased,
        _onNotifyListeners = onNotifyListeners;

  // ---------------------------------------------------------------------------
  // Configuration — set once at construction, snapshot of the session's
  // environment. Immutable for the orchestrator's lifetime.
  // ---------------------------------------------------------------------------
  // ignore: unused_field
  final SttProvider _provider;
  // ignore: unused_field
  final BleAudioCodec _codec;
  final String _sessionId;
  final bool _streamingEnabled;
  // ignore: unused_field
  final CaptureLogService _captureLog;

  /// Active STT provider for this session. Set at construction, immutable.
  SttProvider get provider => _provider;

  /// Audio codec of the incoming stream (Opus from BLE vs PCM16 from mic).
  BleAudioCodec get codec => _codec;

  /// Session identifier. Used as chunk directory name and session key.
  String get sessionId => _sessionId;

  /// Snapshot of `SharedPreferencesUtil.useStreamingPipeline` at construction
  /// time. Kept as a session-constant so a mid-session toggle doesn't flip
  /// the dual-write behaviour under the running queue manager.
  bool get streamingEnabled => _streamingEnabled;

  // ---------------------------------------------------------------------------
  // Injected dependencies — callbacks connect the orchestrator to the
  // pipeline without importing it.
  // ---------------------------------------------------------------------------
  final LocalSttEngineService? _warmEngine;
  // ignore: unused_field
  final void Function(List<TranscriptSegment> segments) _onSegments;
  // ignore: unused_field
  final void Function(bool active) _onVadStateChanged;
  // ignore: unused_field
  final void Function(Object err) _onError;
  final void Function(LocalSttEngineService engine)? _onEngineReleased;
  // ignore: unused_field
  final void Function() _onNotifyListeners;

  // ---------------------------------------------------------------------------
  // Engine (owned by the orchestrator from C2 on; in C1 it's a placeholder
  // that the pipeline will not reach for yet).
  // ---------------------------------------------------------------------------
  LocalSttEngineService? _engine;

  /// Active worker engine, or null while disconnected.
  LocalSttEngineService? get engine => _engine;

  /// Whether the engine came from an external warm-up pool. When true,
  /// [disconnect]/[dispose] must hand it back via [_onEngineReleased]
  /// instead of calling `disconnect()` — the pool keeps it hot.
  bool _engineIsInjected = false;
  bool get engineIsInjected => _engineIsInjected;

  // ---------------------------------------------------------------------------
  // Chunk pipeline state (owned by the orchestrator from C3 on).
  // ---------------------------------------------------------------------------
  AudioChunkWriter? _chunkWriter;
  WavBackupService? _wavBackupService;
  UISegmentController? _segmentController;
  // ignore: unused_field
  IAudioTranscoder? _audioTranscoder;

  /// Bounded segment history for local STT (null before the chunk pipeline
  /// is initialised in C3).
  UISegmentController? get segmentController => _segmentController;

  /// Segments surfaced to the UI. Once C3 wires the controller, this falls
  /// back to an empty list for sessions that haven't produced chunks yet.
  List<TranscriptSegment> get displaySegments =>
      _segmentController?.displaySegments ?? const <TranscriptSegment>[];

  /// Whether any audio has been written to disk but not yet decoded. The
  /// pipeline uses this to avoid cancelling a session that's still producing
  /// its first segment.
  bool get hasUnprocessedAudio =>
      _chunkWriter != null && _chunkWriter!.chunksWritten > 0;

  /// Whether archived pages exist for scroll-up pagination.
  bool get hasArchivedPages => _segmentController?.hasArchivedPages ?? false;

  /// Load an archived page of segments (scroll-up pagination).
  Future<List<TranscriptSegment>> loadArchivedPage(int pageIndex) =>
      _segmentController?.loadPage(pageIndex) ??
      Future.value(const <TranscriptSegment>[]);

  // ---------------------------------------------------------------------------
  // VAD activity indicator — flipped by the worker's VAD callback (wired in
  // C2). Exposed to the UI via a [ValueNotifier].
  // ---------------------------------------------------------------------------
  final ValueNotifier<bool> vadSpeechActive = ValueNotifier<bool>(false);

  // ---------------------------------------------------------------------------
  // Streaming fast-path state projections. These just forward engine-owned
  // values so callers can read them without reaching into the engine
  // directly (keeps the orchestrator the single local-STT façade).
  // ---------------------------------------------------------------------------

  /// Max endTime (seconds) of any segment emitted via the streaming fast
  /// path. Forwarded from the engine. Used by the chunk queue to skip chunks
  /// already covered by streaming when falling back to chunk decode.
  int get streamingWatermarkSec => _engine?.streamingWatermark.ceil() ?? 0;

  /// Whether the streaming fast path is currently healthy. False when the
  /// engine hasn't been constructed yet.
  bool get isStreamingHealthy => _engine?.isStreamingHealthy ?? false;

  // ---------------------------------------------------------------------------
  // Lifecycle — full implementations land in C2/C3/C4. C1 ships placeholders
  // that close what the orchestrator already owns (the VAD notifier).
  // ---------------------------------------------------------------------------

  /// Open the worker + initialise the chunk pipeline. Returns true on
  /// success. Implemented in C2 (engine) + C3 (chunk pipeline).
  Future<bool> connect() async {
    // C2/C3 will fill this in. Until then, callers that instantiate the
    // orchestrator are expected to drive the engine + chunk pipeline
    // themselves via the existing pipeline code path.
    return false;
  }

  /// Stop the worker and reset session state without tearing down the
  /// orchestrator. Implemented in C2/C3.
  Future<void> disconnect() async {
    // No-op until C2.
  }

  /// Send an audio frame through the local pipeline (dual-write: disk
  /// backup + optional streaming fast path). Implemented in C4.
  Future<void> sendAudio(dynamic data) async {
    // No-op until C4.
  }

  /// Re-wire the engine ↔ queue-manager callbacks after a reconnect that
  /// replaced the engine instance but kept writer / controller state.
  /// Implemented in C3.
  Future<void> rewireForReconnect() async {
    // No-op until C3.
  }

  /// Flush any buffered PCM bytes to disk. Used on app-pause to guarantee
  /// recovery files are up to date. Implemented in C4.
  Future<void> flushChunkWriter({bool synchronous = false}) async {
    await _chunkWriter?.flush(synchronous: synchronous);
  }

  /// Tear down the orchestrator. Safe to call multiple times. Subsequent
  /// commits extend this to also dispose the chunk pipeline and release
  /// (or disconnect) the engine.
  Future<void> dispose() async {
    await _chunkWriter?.dispose();
    _chunkWriter = null;
    await _wavBackupService?.stop();
    _wavBackupService = null;
    _segmentController?.dispose();
    _segmentController = null;
    _audioTranscoder = null;

    // Engine release lifecycle moves here in C2. For now, just clear the
    // reference — the pipeline still owns disconnect / release today.
    _engine = null;
    _engineIsInjected = false;

    vadSpeechActive.dispose();
  }

  /// Silence analyzer warnings about fields populated by future commits.
  // ignore: unused_element
  void _retainFutureFields() {
    // Referenced from C2 onwards; keeping the fields live so the skeleton
    // compiles without `unused_field` warnings that noise up the C1 diff.
    if (_warmEngine == null && _onEngineReleased == null) return;
  }
}
