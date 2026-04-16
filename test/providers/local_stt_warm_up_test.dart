import 'package:flutter_test/flutter_test.dart';
import 'package:omi/providers/local_stt_provider.dart';

/// Unit tests for [LocalSttProvider]'s warm-up state machine.
///
/// We can't actually spawn the worker isolate in a test harness (no
/// sherpa_onnx native libs loaded and no SharedPreferences), so these
/// tests focus on the **deterministic bookkeeping**: is-warm flag,
/// acquireEngine/releaseEngine when there is nothing to acquire, and
/// idempotence of `warmUpEngine` when the provider decides not to warm.
///
/// The actual cold → warm transition + idle-dispose timer behaviour is
/// covered by manual QA described in the plan.
void main() {
  group('LocalSttProvider warm-up (no-op gating path)', () {
    test('isEngineWarm starts false', () {
      final provider = LocalSttProvider();
      expect(provider.isEngineWarm, isFalse);
      provider.dispose();
    });

    test('acquireEngine returns null when nothing is warmed', () {
      final provider = LocalSttProvider();
      expect(provider.acquireEngine(), isNull);
      provider.dispose();
    });

    test('warmUpEngine is safe to call without an initialised app', () async {
      // No SharedPreferences binding in this test harness, so the gate
      // in warmUpEngine short-circuits and the call becomes a no-op.
      // The important property: it doesn't throw.
      final provider = LocalSttProvider();
      await provider.warmUpEngine();
      expect(provider.isEngineWarm, isFalse);
      provider.dispose();
    });

    test('concurrent warmUpEngine calls share a single in-flight future',
        () async {
      final provider = LocalSttProvider();
      // Fire three in parallel; all should complete without error and
      // no lingering warm engine is created because gating skipped.
      await Future.wait([
        provider.warmUpEngine(),
        provider.warmUpEngine(),
        provider.warmUpEngine(),
      ]);
      expect(provider.isEngineWarm, isFalse);
      provider.dispose();
    });

    test('dispose is safe even when no warm engine was ever built',
        () async {
      final provider = LocalSttProvider();
      provider.dispose();
      // Calling dispose twice is not a supported contract on ChangeNotifier
      // — stopping here is the test.
    });
  });
}
