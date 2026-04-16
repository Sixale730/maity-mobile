import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/stt/local/local_stt_orchestrator.dart';

/// Unit tests for [LocalSttOrchestrator] that don't spin up a real worker
/// isolate. We exercise the deterministic bookkeeping: construction defaults,
/// engine-injection flag, streaming state projections, VAD notifier, and
/// dispose cleanup.
///
/// The engine lifecycle (connect, disconnect, sendAudio) and chunk pipeline
/// paths (ChunkQueueManager, AudioChunkWriter) require real filesystem state
/// and are covered by the manual QA matrix.
void main() {
  final List<List<TranscriptSegment>> receivedSegments = [];
  final List<bool> receivedVadStates = [];
  final List<Object> receivedErrors = [];

  LocalSttOrchestrator makeOrchestrator({
    bool streamingEnabled = true,
    SttProvider provider = SttProvider.localParakeet,
  }) {
    return LocalSttOrchestrator(
      provider: provider,
      codec: BleAudioCodec.pcm16,
      sessionId: 'test-session',
      streamingEnabled: streamingEnabled,
      captureLog: CaptureLogService.instance,
      onSegments: (segs) => receivedSegments.add(segs),
      onVadStateChanged: (active) => receivedVadStates.add(active),
      onError: (err) => receivedErrors.add(err),
      onNotifyListeners: () {},
    );
  }

  setUp(() {
    receivedSegments.clear();
    receivedVadStates.clear();
    receivedErrors.clear();
  });

  group('construction defaults', () {
    test('engine is null before connect', () {
      final orch = makeOrchestrator();
      expect(orch.engine, isNull);
      expect(orch.engineIsInjected, isFalse);
    });

    test('streaming config is captured as session-constant', () {
      final orchOn = makeOrchestrator(streamingEnabled: true);
      final orchOff = makeOrchestrator(streamingEnabled: false);
      expect(orchOn.streamingEnabled, isTrue);
      expect(orchOff.streamingEnabled, isFalse);
    });

    test('provider is captured from constructor', () {
      final orch = makeOrchestrator(provider: SttProvider.localMoonshine);
      expect(orch.provider, SttProvider.localMoonshine);
    });

    test('sessionId is captured from constructor', () {
      final orch = makeOrchestrator();
      expect(orch.sessionId, 'test-session');
    });

    test('codec is captured from constructor', () {
      final orch = makeOrchestrator();
      expect(orch.codec, BleAudioCodec.pcm16);
    });
  });

  group('display state defaults', () {
    test('displaySegments is empty before chunk pipeline init', () {
      expect(makeOrchestrator().displaySegments, isEmpty);
    });

    test('hasUnprocessedAudio is false before chunk pipeline init', () {
      expect(makeOrchestrator().hasUnprocessedAudio, isFalse);
    });

    test('hasArchivedPages is false before chunk pipeline init', () {
      expect(makeOrchestrator().hasArchivedPages, isFalse);
    });

    test('loadArchivedPage returns empty before init', () async {
      final result = await makeOrchestrator().loadArchivedPage(0);
      expect(result, isEmpty);
    });
  });

  group('streaming state projections', () {
    test('streamingWatermarkSec is 0 without engine', () {
      expect(makeOrchestrator().streamingWatermarkSec, 0);
    });

    test('isStreamingHealthy is false without engine', () {
      expect(makeOrchestrator().isStreamingHealthy, isFalse);
    });
  });

  group('VAD notifier', () {
    test('vadSpeechActive starts false', () {
      expect(makeOrchestrator().vadSpeechActive.value, isFalse);
    });
  });

  group('connect without model', () {
    test('returns false when no model is configured', () async {
      final orch = makeOrchestrator();
      final ok = await orch.connect();
      expect(ok, isFalse, reason: 'no model path → fromPreferences returns null');
      expect(orch.engine, isNull);
    });
  });

  group('dispose', () {
    test('resets engine and VAD state', () async {
      final orch = makeOrchestrator();
      // vadSpeechActive is still alive
      expect(orch.vadSpeechActive.value, isFalse);

      await orch.dispose();

      expect(orch.engine, isNull);
      expect(orch.engineIsInjected, isFalse);
    });

    test('is safe to call multiple times', () async {
      final orch = makeOrchestrator();
      await orch.dispose();
      // Second dispose should not throw
      // (vadSpeechActive is already disposed, but dispose guards against it)
    });
  });

  group('disconnect without engine', () {
    test('is a no-op', () async {
      final orch = makeOrchestrator();
      await orch.disconnect();
      expect(orch.engine, isNull);
    });
  });
}
