import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:omi/utils/app_state_collector.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Always-on crash log manager that persists errors to a local JSONL file.
///
/// Unlike [DebugLogManager] (opt-in via developer settings), this is
/// unconditionally active. Uses synchronous file writes to guarantee
/// persistence even when the process is about to die.
///
/// Logs are uploaded to Supabase `platform_logs` on the next app launch
/// by [CrashLogUploadService].
class CrashLogManager {
  CrashLogManager._internal();
  static final CrashLogManager instance = CrashLogManager._internal();

  static const String _fileName = 'crash_log.jsonl';
  static const int _maxFileBytes = 500 * 1024; // 500KB
  static const int _maxStackTraceChars = 4000;
  static const int _maxErrorMessageChars = 1000;

  static final DateFormat _ts = DateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");

  String? _filePath;
  final String _sessionId = const Uuid().v4();
  String? _appVersion;
  String? _deviceInfo;
  String? _platform;
  bool _initialized = false;

  /// Initialize the crash log manager. Call early in app startup,
  /// after [SharedPreferencesUtil.init()] but before [runApp].
  Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _filePath = '${dir.path}/$_fileName';

      // Cache device info
      try {
        final info = await PackageInfo.fromPlatform();
        _appVersion = '${info.version}+${info.buildNumber}';
      } catch (_) {
        _appVersion = 'unknown';
      }

      _platform = Platform.isAndroid
          ? 'android'
          : Platform.isIOS
              ? 'ios'
              : Platform.isWindows
                  ? 'windows'
                  : Platform.isMacOS
                      ? 'macos'
                      : Platform.isLinux
                          ? 'linux'
                          : 'unknown';

      _deviceInfo = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

      _initialized = true;
    } catch (e) {
      debugPrint('[CrashLogManager] init failed: $e');
    }
  }

  /// Log a crash/error entry. Uses **synchronous** file I/O to guarantee
  /// the entry is written before the process potentially dies.
  ///
  /// [error] The error object.
  /// [stack] Optional stack trace.
  /// [source] Where the error was caught (e.g. 'flutter_error', 'zone_error').
  /// [context] Optional extra context (e.g. user attributes from CrashlyticsManager).
  void logCrash(
    Object error,
    StackTrace? stack, {
    String? source,
    Map<String, dynamic>? context,
  }) {
    try {
      if (_filePath == null) return;

      final file = File(_filePath!);

      // Rotate if needed
      _rotateIfNeeded(file);

      final errorType = error.runtimeType.toString();
      final errorMessage = _truncate(error.toString(), _maxErrorMessageChars);
      final stackTrace = stack != null ? _truncate(stack.toString(), _maxStackTraceChars) : null;

      // Collect app state snapshot (never throws)
      Map<String, dynamic>? appState;
      try {
        appState = AppStateCollector.snapshot();
        if (context != null) {
          appState.addAll(context);
        }
      } catch (_) {
        appState = context;
      }

      final entry = <String, dynamic>{
        'ts': _ts.format(DateTime.now().toUtc()),
        'session_id': _sessionId,
        'error_type': errorType,
        'error_message': errorMessage,
        if (stackTrace != null) 'stack_trace': stackTrace,
        'source': source ?? 'unknown',
        if (appState != null && appState.isNotEmpty) 'app_state': appState,
        'app_version': _appVersion,
        'device_info': _deviceInfo,
        'platform': _platform,
      };

      // Synchronous write — guarantees persistence before process death
      file.writeAsStringSync('${jsonEncode(entry)}\n', mode: FileMode.append, flush: true);
    } catch (e) {
      // Swallow — crash logging must never itself crash the app
      debugPrint('[CrashLogManager] logCrash failed: $e');
    }
  }

  /// Whether there are pending crash logs to upload.
  bool hasPendingLogs() {
    try {
      if (_filePath == null) return false;
      final file = File(_filePath!);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Read all pending crash log entries.
  List<Map<String, dynamic>> readPendingLogs() {
    try {
      if (_filePath == null) return const [];
      final file = File(_filePath!);
      if (!file.existsSync()) return const [];

      final content = file.readAsStringSync();
      if (content.trim().isEmpty) return const [];

      final entries = <Map<String, dynamic>>[];
      for (final line in content.split('\n')) {
        if (line.trim().isEmpty) continue;
        try {
          final parsed = jsonDecode(line);
          if (parsed is Map<String, dynamic>) {
            entries.add(parsed);
          }
        } catch (_) {
          // Skip malformed lines
        }
      }
      return entries;
    } catch (e) {
      debugPrint('[CrashLogManager] readPendingLogs failed: $e');
      return const [];
    }
  }

  /// Clear all crash logs after successful upload.
  void clearLogs() {
    try {
      if (_filePath == null) return;
      final file = File(_filePath!);
      if (file.existsSync()) {
        file.writeAsStringSync('', mode: FileMode.write, flush: true);
      }
    } catch (e) {
      debugPrint('[CrashLogManager] clearLogs failed: $e');
    }
  }

  /// Truncate from the front if file exceeds size cap.
  void _rotateIfNeeded(File file) {
    try {
      if (!file.existsSync()) return;
      final len = file.lengthSync();
      if (len <= _maxFileBytes) return;

      // Read all lines, keep the last ~60%
      final content = file.readAsStringSync();
      final lines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final keepFrom = (lines.length * 0.4).round();
      final kept = lines.sublist(keepFrom).join('\n');
      file.writeAsStringSync('$kept\n', mode: FileMode.write, flush: true);
    } catch (_) {
      // If rotation fails, just continue — worst case the file is a bit large
    }
  }

  static String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}...[truncated]';
  }
}
