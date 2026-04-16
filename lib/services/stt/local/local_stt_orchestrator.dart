import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/recording/ui_segment_controller.dart';
import 'package:omi/services/recording/wav_backup_service.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart'
    show AudioTranscoderFactory, IAudioTranscoder;
import 'package:omi/services/recording/telemetry_collector.dart';
import 'package:omi/services/stt/local/audio_chunk_writer.dart';
import 'package:omi/services/stt/local/chunk_queue_manager.dart';
import 'package:omi/services/stt/local/device_memory_service.dart';
import 'package:omi/services/stt/local/local_stt_engine_service.dart';
import 'package:omi/services/stt/local/local_stt_model_type.dart';
import 'package:omi/utils/debug_log_manager.dart';

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
  final SttProvider _provider;
  // ignore: unused_field
  final BleAudioCodec _codec;
  final String _sessionId;
  final bool _streamingEnabled;
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
  final void Function(List<TranscriptSegment> segments) _onSegments;
  final void Function(bool active) _onVadStateChanged;
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
  // Engine lifecycle (C2)
  // ---------------------------------------------------------------------------

  /// Open the worker isolate. If a warm engine was supplied at construction
  /// and it's already connected, reuses it (zero cold-start latency); falls
  /// back to a cold build from preferences otherwise.
  ///
  /// Returns true when the engine is live and callbacks are wired. Chunk
  /// pipeline initialisation (C3) runs after this returns; the caller chains
  /// both steps.
  Future<bool> connect() async {
    LocalSttEngineService? engine = _warmEngine;
    if (engine != null && engine.isConnected) {
      _engineIsInjected = true;
      _wireEngineCallbacks(engine);
    } else {
      _engineIsInjected = false;
      engine = _createEngineFromConfig();
      if (engine == null) {
        _captureLog.log('socket', 'local_stt_init_failed',
            severity: 'error', details: {'provider': _provider.name});
        return false;
      }
      _wireEngineCallbacks(engine);
      final ok = await engine.connect();
      if (!ok) {
        debugPrint('[LocalSttOrchestrator] engine connect failed');
        _captureLog.log('socket', 'local_stt_connect_failed',
            severity: 'error');
        return false;
      }
    }
    _engine = engine;
    return true;
  }

  /// Hands the engine back to its owner (warm pool) or disconnects it.
  ///
  /// When the engine was injected via the warm pool, we flush residual VAD
  /// audio and invoke [_onEngineReleased] so the provider can recycle it.
  /// When it was cold-built, we own it and must `disconnect()` to free the
  /// ~640 MB of model RAM.
  Future<void> disconnect() async {
    final engine = _engine;
    if (engine == null) return;
    _engine = null;

    if (_engineIsInjected) {
      _engineIsInjected = false;
      try {
        await engine.flush();
      } catch (e) {
        debugPrint('[LocalSttOrchestrator] flush on release error: $e');
      }
      _onEngineReleased?.call(engine);
    } else {
      await engine.disconnect();
    }
  }

  /// Build a [LocalSttEngineService] from the user's preferences. Mirrors
  /// the config-reading logic used by [TranscriptionPipeline]. Returns null
  /// when the model path isn't configured.
  LocalSttEngineService? _createEngineFromConfig() {
    final modelType = switch (_provider) {
      SttProvider.localMoonshine => LocalSttModelType.moonshine,
      SttProvider.localCanary => LocalSttModelType.canary,
      _ => LocalSttModelType.parakeet,
    };
    return LocalSttEngineService.fromPreferences(modelType);
  }

  /// Hook the engine's typed callbacks into the orchestrator's injected
  /// callbacks. Done during [connect] before the engine starts producing
  /// segments so no events are lost.
  void _wireEngineCallbacks(LocalSttEngineService engine) {
    engine.onSegments = _onSegments;
    engine.onVadStateChanged = (active) {
      if (vadSpeechActive.value != active) {
        vadSpeechActive.value = active;
      }
      _onVadStateChanged(active);
    };
    engine.onError = (err, _) => _onError(err);
    // onStreamingHealthChanged and onChunkProcessed are wired by
    // _wireChunkSocketCallbacks (C3) once the chunk pipeline is initialized.
  }

  // ---------------------------------------------------------------------------
  // Chunk pipeline (C3)
  // ---------------------------------------------------------------------------

  /// Initialize chunk writer + queue manager + segment controller. On
  /// reconnect (when [_chunkWriter] already exists), only re-wires the new
  /// engine's callbacks and resumes queue processing — does NOT recreate the
  /// writer, segment controller, or session.
  Future<void> initChunkPipeline() async {
    final queueManager = ChunkQueueManager.instance;

    // --- Reconnect path: pipeline already exists, just re-wire socket ---
    if (_chunkWriter != null) {
      debugPrint(
          '[LocalSttOrchestrator] Chunk pipeline exists — re-wiring for reconnect');
      _wireChunkSocketCallbacks(queueManager);
      queueManager.processNextChunk(_sessionId);
      return;
    }

    // --- First-time path: create writer, controller, session ---
    await queueManager.initialize();
    queueManager.setMaxQueueSize(DeviceMemoryService.cachedQueueCap);
    final sessionDir = await queueManager.startSession(_sessionId);

    _chunkWriter = AudioChunkWriter(
      sessionId: _sessionId,
      baseDir: sessionDir,
      onChunkWritten: (meta) => queueManager.enqueueChunk(meta),
    );
    _chunkWriter!.start();

    _wavBackupService = WavBackupService();
    await _wavBackupService!.start(_sessionId);

    // Create audio transcoder for non-PCM16 codecs (BLE/OMI sends Opus).
    if (_codec != BleAudioCodec.pcm16) {
      _audioTranscoder = AudioTranscoderFactory.createToRawPcm(
        sourceCodec: _codec,
        sampleRate: 16000,
      );
      debugPrint(
          '[LocalSttOrchestrator] Audio transcoder: ${_codec.name} → PCM16');
    } else {
      _audioTranscoder = null;
    }

    _segmentController = UISegmentController();
    _segmentController!.startSession(_sessionId, sessionDir);

    _wireChunkSocketCallbacks(queueManager);

    debugPrint(
        '[LocalSttOrchestrator] Chunk pipeline initialized for session $_sessionId');
  }

  /// Wire ChunkQueueManager ↔ LocalSttEngineService callbacks. Shared by
  /// first-init and reconnect paths.
  void _wireChunkSocketCallbacks(ChunkQueueManager queueManager) {
    final engine = _engine;
    if (engine == null) return;

    queueManager.onProcessChunk = (chunk) {
      engine.processChunkFile(
        chunk.filePath,
        '${chunk.sessionId}_${chunk.sequence}',
        chunk.offsetSeconds,
      );
    };

    engine.onChunkProcessed = (chunkId) {
      final parts = chunkId.split('_');
      if (parts.length >= 2) {
        final seq = int.tryParse(parts.last);
        final sid = parts.sublist(0, parts.length - 1).join('_');
        if (seq != null) {
          queueManager.markCompleted(sid, seq);
        }
      }
    };

    engine.onVadStateChanged = (active) {
      if (vadSpeechActive.value != active) {
        vadSpeechActive.value = active;
      }
      _onVadStateChanged(active);
    };

    if (_streamingEnabled) {
      queueManager.switchMode(ChunkProcessingMode.streamPrimary);
      TelemetryCollector.instance.recordStreamingEvent('streaming_started');
    }
    engine.onStreamingHealthChanged = (healthy, reason) {
      debugPrint(
          '[LocalSttOrchestrator] Streaming health: $healthy ($reason)');
      DebugLogManager.logEvent('streaming_health_changed', {
        'healthy': healthy,
        'reason': reason,
        'watermark_sec': engine.streamingWatermark,
      });
      TelemetryCollector.instance.recordStreamingEvent(
        healthy ? 'streaming_recovered' : 'streaming_fallback',
        details: {
          'reason': reason,
          'watermark_sec': engine.streamingWatermark,
        },
      );
      if (!healthy) {
        queueManager.switchMode(
          ChunkProcessingMode.chunkPrimary,
          streamingWatermarkSec: engine.streamingWatermark,
          sessionId: _sessionId,
        );
      } else {
        queueManager.switchMode(ChunkProcessingMode.streamPrimary);
      }
    };
  }

  /// Re-wire the engine ↔ queue-manager callbacks after a reconnect that
  /// replaced the engine instance but kept writer / controller state.
  Future<void> rewireForReconnect() async {
    await initChunkPipeline();
  }

  /// Route an audio frame through the local pipeline:
  /// 1. Transcode if needed (Opus → PCM16).
  /// 2. Write to chunk writer (disk backup — always on).
  /// 3. Write to WAV backup (crash-safety).
  /// 4. Push to engine streaming fast path (if [_streamingEnabled]).
  void sendAudio(List<int> data) {
    if (_chunkWriter == null) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    Uint8List pcmBytes;
    try {
      pcmBytes = _audioTranscoder != null
          ? _audioTranscoder!.transcode(bytes)
          : bytes;
    } catch (e) {
      debugPrint('[LocalSttOrchestrator] Transcode error, skipping: $e');
      return;
    }
    if (pcmBytes.isEmpty) return;
    _chunkWriter!.addBytes(pcmBytes);
    _wavBackupService?.writeAudio(pcmBytes);
    if (_streamingEnabled) {
      _engine?.pushAudio(pcmBytes);
    }
  }

  /// Flush any buffered PCM bytes to disk. Used on app-pause to guarantee
  /// recovery files are up to date.
  Future<void> flushChunkWriter({bool synchronous = false}) async {
    await _chunkWriter?.flush(synchronous: synchronous);
  }

  /// Tear down the orchestrator. Safe to call multiple times.
  Future<void> dispose() async {
    await _chunkWriter?.dispose();
    _chunkWriter = null;
    await _wavBackupService?.stop();
    _wavBackupService = null;
    _segmentController?.dispose();
    _segmentController = null;
    _audioTranscoder = null;

    await disconnect();

    vadSpeechActive.dispose();
  }
}
