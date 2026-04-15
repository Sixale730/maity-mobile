import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/local_stt/chunk_meta.dart';
import 'package:omi/services/local_stt/chunk_queue_manager.dart';

/// These tests cover the dual-mode behavior introduced for the streaming
/// fast path. They don't touch disk persistence — the singleton is reset
/// between cases and chunks are enqueued in memory via the public API.
///
/// We skip `initialize()` and `_saveIndex` because they touch disk; each
/// test drives the manager purely through [enqueueChunk] + [switchMode],
/// which is enough to validate the queue-level decision logic.
void main() {
  ChunkMeta makeChunk({
    required String sessionId,
    required int sequence,
    int byteCount = 32000 * 5, // 5s of PCM16 at 16kHz
  }) {
    return ChunkMeta(
      sessionId: sessionId,
      sequence: sequence,
      filePath: '/tmp/$sessionId/$sequence.pcm',
      byteCount: byteCount,
      createdAt: DateTime.now(),
    );
  }

  setUp(() {
    ChunkQueueManager.instance.reset();
  });

  group('streamPrimary mode', () {
    test('enqueueChunk does not dispatch to onProcessChunk', () async {
      final qm = ChunkQueueManager.instance;
      await qm.switchMode(ChunkProcessingMode.streamPrimary);

      var dispatchCount = 0;
      qm.onProcessChunk = (_) => dispatchCount++;

      await qm.enqueueChunk(makeChunk(sessionId: 's1', sequence: 0));
      await qm.enqueueChunk(makeChunk(sessionId: 's1', sequence: 1));

      expect(dispatchCount, 0,
          reason: 'chunks must accumulate as disk backup only in streamPrimary');
    });
  });

  group('chunkPrimary mode', () {
    test('enqueueChunk dispatches each new chunk to the worker', () async {
      final qm = ChunkQueueManager.instance;
      // Default mode is chunkPrimary, but be explicit for clarity.
      await qm.switchMode(ChunkProcessingMode.chunkPrimary);

      final dispatched = <int>[];
      qm.onProcessChunk = (c) => dispatched.add(c.sequence);

      await qm.enqueueChunk(makeChunk(sessionId: 's1', sequence: 0));

      expect(dispatched, [0]);
    });
  });

  group('switchMode(chunkPrimary, watermark)', () {
    test('marks chunks fully covered by watermark as deleted', () async {
      final qm = ChunkQueueManager.instance;
      await qm.switchMode(ChunkProcessingMode.streamPrimary);

      // Enqueue 4 chunks in stream mode: offsets 0, 5, 10, 15 (each 5s long).
      for (var i = 0; i < 4; i++) {
        await qm.enqueueChunk(makeChunk(sessionId: 's1', sequence: i));
      }

      // Streaming emitted segments up to 12s. Chunks 0 (0-5) and 1 (5-10)
      // are fully covered; chunk 2 (10-15) overlaps and must stay pending;
      // chunk 3 (15-20) is fully uncovered.
      final dispatched = <int>[];
      qm.onProcessChunk = (c) => dispatched.add(c.sequence);

      await qm.switchMode(
        ChunkProcessingMode.chunkPrimary,
        streamingWatermarkSec: 12.0,
        sessionId: 's1',
      );

      // After the switch, the queue kicks onProcessChunk for the oldest
      // pending chunk. Only chunks 2 and 3 remain pending, so chunk 2 is
      // dispatched. (Chunk 3 follows when chunk 2 completes.)
      expect(dispatched.first, 2,
          reason: 'chunks 0 and 1 were fully covered by watermark 12s');
    });

    test('leaves all chunks pending when watermark is 0', () async {
      final qm = ChunkQueueManager.instance;
      await qm.switchMode(ChunkProcessingMode.streamPrimary);

      for (var i = 0; i < 3; i++) {
        await qm.enqueueChunk(makeChunk(sessionId: 's1', sequence: i));
      }

      final dispatched = <int>[];
      qm.onProcessChunk = (c) => dispatched.add(c.sequence);

      await qm.switchMode(
        ChunkProcessingMode.chunkPrimary,
        streamingWatermarkSec: 0.0,
        sessionId: 's1',
      );

      expect(dispatched.first, 0,
          reason: 'with watermark=0 no chunks are covered, so oldest pending dispatches');
    });
  });

  group('switchMode(streamPrimary) after fallback', () {
    test('new chunks stop being dispatched', () async {
      final qm = ChunkQueueManager.instance;
      await qm.switchMode(ChunkProcessingMode.chunkPrimary);

      var dispatchCount = 0;
      qm.onProcessChunk = (_) => dispatchCount++;

      await qm.enqueueChunk(makeChunk(sessionId: 's1', sequence: 0));
      expect(dispatchCount, 1);

      await qm.switchMode(ChunkProcessingMode.streamPrimary);
      await qm.enqueueChunk(makeChunk(sessionId: 's1', sequence: 1));

      expect(dispatchCount, 1,
          reason: 'after returning to streamPrimary, new chunks should not dispatch');
    });
  });
}
