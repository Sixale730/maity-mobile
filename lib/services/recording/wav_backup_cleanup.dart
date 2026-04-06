import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:omi/services/recording/wav_backup_service.dart';

/// Delete WAV backup files older than [retentionDays].
///
/// Called once on app startup (fire-and-forget). Scans the
/// `wav_recordings/` directory and deletes files whose last modification
/// time is older than the retention period.
///
/// Default retention: 7 days (~4 GB max for heavy users).
Future<void> cleanupOldWavBackups({int retentionDays = 7}) async {
  try {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory('${appSupport.path}/${WavBackupService.wavDirName}');
    if (!dir.existsSync()) return;

    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    var deletedCount = 0;
    var freedBytes = 0;

    final entries = dir.listSync();
    for (final entry in entries) {
      if (entry is File && entry.path.endsWith('.wav')) {
        final stat = entry.statSync();
        if (stat.modified.isBefore(cutoff)) {
          freedBytes += stat.size;
          entry.deleteSync();
          deletedCount++;
        }
      }
    }

    if (deletedCount > 0) {
      debugPrint('[WavCleanup] Deleted $deletedCount old backups '
          '(freed ${(freedBytes / 1024 / 1024).toStringAsFixed(1)} MB)');
    }
  } catch (e) {
    debugPrint('[WavCleanup] Cleanup error: $e');
  }
}
