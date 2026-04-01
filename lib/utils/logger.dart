import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:omi/utils/crash_log_manager.dart';
import 'package:omi/utils/debug_log_manager.dart';

class SimpleTalkerObserver extends TalkerObserver {
  SimpleTalkerObserver();

  @override
  void onError(err) {
    debugPrint('[Logger Error] ${err.error}');
    debugPrint('[Logger Stack] ${err.stackTrace}');
  }

  @override
  void onException(err) {
    debugPrint('[Logger Exception] ${err.exception}');
    debugPrint('[Logger Stack] ${err.stackTrace}');
  }
}

class Logger {
  final simpleTalkerObserver = SimpleTalkerObserver();
  late final talker = TalkerFlutter.init(observer: simpleTalkerObserver);

  Logger._();

  static final Logger _instance = Logger._();

  static Logger get instance => _instance;

  static void log(dynamic message) {
    instance.talker.log(message);
  }

  static void error(dynamic message) {
    instance.talker.error(message);
    DebugLogManager.logError(message);
    CrashLogManager.instance.logCrash(message, null, source: 'logger_error');
  }

  static void warning(dynamic message) {
    instance.talker.warning(message);
    DebugLogManager.logWarning(message.toString());
  }

  static void info(dynamic message) {
    instance.talker.info(message);
  }

  static void debug(dynamic message) {
    instance.talker.debug(message);
  }

  static void handle(dynamic exception, StackTrace? stackTrace, {String? message}) {
    instance.talker.handle(exception, stackTrace, message ?? 'An error occurred. Please try again later.');
    DebugLogManager.logError(exception, stackTrace, message);
    CrashLogManager.instance.logCrash(exception, stackTrace, source: 'logger_handle');
  }
}

class LoggerSnackbar extends StatelessWidget {
  final TalkerError? error;
  final TalkerException? exception;

  const LoggerSnackbar({super.key, this.error, this.exception}) : assert(error != null || exception != null);

  @override
  Widget build(BuildContext context) {
    final data = error ?? exception!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(0),
        leading: const Icon(Icons.error_outline, color: Colors.white),
        title: Text(
          data.message ?? 'Something went wrong! Please try again later.',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.share, color: Colors.white),
          onPressed: () async {
            // Intercom disabled
          },
        ),
      ),
    );
  }
}
