import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/crash_log_manager.dart';

/// Fake type whose `runtimeType.toString()` matches the gotrue symbol we
/// want to filter, without importing the private class.
class AuthRetryableFetchException implements Exception {
  @override
  String toString() => 'AuthRetryableFetchException: Failed host lookup';
}

void main() {
  group('CrashLogManager.shouldIgnore', () {
    test('drops AuthRetryableFetchException', () {
      expect(CrashLogManager.shouldIgnore('AuthRetryableFetchException'), isTrue);
    });

    test('matches by runtime type of a concrete instance', () {
      final err = AuthRetryableFetchException();
      expect(
        CrashLogManager.shouldIgnore(err.runtimeType.toString()),
        isTrue,
        reason: 'runtime type match is the mechanism used by logCrash',
      );
    });

    test('keeps unrelated error types', () {
      expect(CrashLogManager.shouldIgnore('StateError'), isFalse);
      expect(CrashLogManager.shouldIgnore('FlutterError'), isFalse);
      expect(CrashLogManager.shouldIgnore('SocketException'), isFalse);
      expect(CrashLogManager.shouldIgnore(''), isFalse);
    });
  });
}
