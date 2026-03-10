import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/notifications/notification_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// A pending upload entry in the queue.
class PendingUpload {
  final String id;
  final String filePath;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String? userId;
  final String source;
  int retryCount;
  DateTime? lastRetryAt;
  final String? structuredJson;

  PendingUpload({
    required this.id,
    required this.filePath,
    required this.startedAt,
    required this.finishedAt,
    this.userId,
    this.source = 'omi',
    this.retryCount = 0,
    this.lastRetryAt,
    this.structuredJson,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'file_path': filePath,
        'started_at': startedAt.toUtc().toIso8601String(),
        'finished_at': finishedAt.toUtc().toIso8601String(),
        'user_id': userId,
        'source': source,
        'retry_count': retryCount,
        'last_retry_at': lastRetryAt?.toUtc().toIso8601String(),
        'structured_json': structuredJson,
      };

  factory PendingUpload.fromJson(Map<String, dynamic> json) => PendingUpload(
        id: json['id'] as String,
        filePath: json['file_path'] as String,
        startedAt: DateTime.parse(json['started_at'] as String),
        finishedAt: DateTime.parse(json['finished_at'] as String),
        userId: json['user_id'] as String?,
        source: (json['source'] as String?) ?? 'omi',
        retryCount: (json['retry_count'] as int?) ?? 0,
        lastRetryAt: json['last_retry_at'] != null
            ? DateTime.parse(json['last_retry_at'] as String)
            : null,
        structuredJson: json['structured_json'] as String?,
      );
}

/// Manages a persistent queue of conversations pending upload to the backend.
///
/// This is the core of the local-first architecture:
/// 1. Conversations are saved to local JSON files when recording finishes
/// 2. Queued for background upload via `enqueue()`
/// 3. Uploaded to `POST /v1/omi/conversations/store-and-process`
/// 4. On failure, retried with exponential backoff (max 3 retries)
/// 5. On app launch, pending uploads are processed automatically
class BackgroundUploadService {
  BackgroundUploadService._();
  static final BackgroundUploadService _instance = BackgroundUploadService._();
  static BackgroundUploadService get instance => _instance;

  static String get _baseUrl =>
      Env.maityBackendUrl ?? 'https://maity-mobile.vercel.app';

  static const int _maxRetries = 3;
  static const String _queueFileName = 'pending_uploads.json';
  static const String _uploadsDir = 'pending_conversations';

  final ValueNotifier<bool> uploadCompleted = ValueNotifier(false);

  List<PendingUpload> _queue = [];
  bool _isProcessing = false;
  Timer? _retryTimer;

  CaptureLogService get _captureLog => CaptureLogService.instance;

  /// Number of items currently in the queue.
  int get pendingCount => _queue.length;

  /// Whether the service is currently processing uploads.
  bool get isProcessing => _isProcessing;

  /// Initialize the service: load queue from disk and process pending items.
  Future<void> initialize() async {
    await _loadQueue();
    if (_queue.isNotEmpty) {
      debugPrint(
          '[BackgroundUpload] Found ${_queue.length} pending uploads on launch');
      // Process after a short delay to let auth settle
      Future.delayed(const Duration(seconds: 3), () => processQueue());
    }
  }

  /// Enqueue a conversation for background upload.
  ///
  /// Saves segment data to a JSON file and adds an entry to the persistent queue.
  Future<String> enqueue({
    required List<TranscriptSegment> segments,
    required DateTime startedAt,
    required DateTime finishedAt,
    String? userId,
    String source = 'omi',
    Map<String, dynamic>? structured,
  }) async {
    final id = const Uuid().v4();

    // Save segments to a dedicated JSON file
    final dir = await _getUploadsDirectory();
    final filePath = '${dir.path}/$id.json';
    final segmentMaps = segments.map((s) => s.toJson()).toList();
    final jsonString = await compute(_encodeJsonList, segmentMaps);
    await File(filePath).writeAsString(jsonString);

    final upload = PendingUpload(
      id: id,
      filePath: filePath,
      startedAt: startedAt,
      finishedAt: finishedAt,
      userId: userId,
      source: source,
      structuredJson: structured != null ? jsonEncode(structured) : null,
    );

    _queue.add(upload);
    await _saveQueue();

    _captureLog.log('upload', 'enqueued', details: {
      'upload_id': id,
      'segments_count': segments.length,
      'queue_size': _queue.length,
    });
    debugPrint(
        '[BackgroundUpload] Enqueued upload $id (${segments.length} segments)');

    // Trigger processing
    processQueue();

    return id;
  }

  /// Process all pending uploads in the queue.
  Future<void> processQueue() async {
    if (_isProcessing) return;
    if (_queue.isEmpty) return;

    _isProcessing = true;

    try {
      // Process a copy to allow mutation during iteration
      final toProcess = List<PendingUpload>.from(_queue);

      for (final upload in toProcess) {
        // Skip if already exceeded max retries
        if (upload.retryCount >= _maxRetries) {
          debugPrint(
              '[BackgroundUpload] Upload ${upload.id} exceeded max retries, keeping in queue');
          continue;
        }

        // Respect backoff: skip if not enough time has passed since last retry
        if (upload.lastRetryAt != null) {
          final backoffSeconds = _getBackoffSeconds(upload.retryCount);
          final elapsed =
              DateTime.now().difference(upload.lastRetryAt!).inSeconds;
          if (elapsed < backoffSeconds) {
            continue;
          }
        }

        final success = await _uploadConversation(upload);

        if (success) {
          _queue.removeWhere((u) => u.id == upload.id);
          await _deleteUploadFile(upload.filePath);
          await _saveQueue();

          _captureLog.log('upload', 'upload_success', details: {
            'upload_id': upload.id,
          });
          debugPrint('[BackgroundUpload] Upload ${upload.id} succeeded');

          // Notify listeners that an upload completed
          uploadCompleted.value = !uploadCompleted.value;
        } else {
          upload.retryCount++;
          upload.lastRetryAt = DateTime.now();
          await _saveQueue();

          _captureLog.log('upload', 'upload_failed', severity: 'warning',
              details: {
            'upload_id': upload.id,
            'retry_count': upload.retryCount,
            'max_retries': _maxRetries,
          });
          debugPrint(
              '[BackgroundUpload] Upload ${upload.id} failed (attempt ${upload.retryCount}/$_maxRetries)');
        }
      }

      // Clean up permanently failed uploads (dead letter removal)
      final deadItems =
          _queue.where((u) => u.retryCount >= _maxRetries).toList();
      for (final dead in deadItems) {
        debugPrint(
            '[BackgroundUpload] Removing permanently failed upload: ${dead.id}');
        _captureLog.log('upload', 'upload_permanently_failed',
            severity: 'error', details: {
          'id': dead.id,
          'retry_count': dead.retryCount,
        });
        await _deleteUploadFile(dead.filePath);
        _queue.remove(dead);
      }
      if (deadItems.isNotEmpty) {
        await _saveQueue();
        NotificationService.instance.createNotification(
          title: 'Upload Failed',
          body:
              '${deadItems.length} recording(s) could not be uploaded after multiple attempts.',
          notificationId: 4,
        );
      }

      // Schedule retry if there are still pending items
      if (_queue.any((u) => u.retryCount < _maxRetries)) {
        _scheduleRetry();
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// Upload a single conversation to the backend.
  Future<bool> _uploadConversation(PendingUpload upload) async {
    try {
      // Read segments from file
      final file = File(upload.filePath);
      if (!await file.exists()) {
        debugPrint(
            '[BackgroundUpload] File not found: ${upload.filePath}, removing from queue');
        return true; // Remove from queue since file is gone
      }

      final content = await file.readAsString();
      final segments = jsonDecode(content) as List<dynamic>;

      // Build request body
      final body = <String, dynamic>{
        'segments': segments,
        'started_at': upload.startedAt.toUtc().toIso8601String(),
        'finished_at': upload.finishedAt.toUtc().toIso8601String(),
        'source': upload.source,
      };

      if (upload.userId != null) {
        body['user_id'] = upload.userId;
      }

      if (upload.structuredJson != null) {
        body['structured'] = jsonDecode(upload.structuredJson!);
      }

      final response = await makeApiCall(
        url: '$_baseUrl/v1/omi/conversations/store-and-process',
        headers: {},
        body: jsonEncode(body),
        method: 'POST',
      );

      if (response == null) return false;

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      }

      debugPrint(
          '[BackgroundUpload] Server returned ${response.statusCode}: ${response.body}');
      return false;
    } catch (e) {
      debugPrint('[BackgroundUpload] Upload error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Queue persistence
  // ---------------------------------------------------------------------------

  Future<void> _loadQueue() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_queueFileName');

      if (!await file.exists()) {
        _queue = [];
        return;
      }

      final content = await file.readAsString();
      if (content.isEmpty) {
        _queue = [];
        return;
      }

      final list = jsonDecode(content) as List<dynamic>;
      _queue = list
          .map((e) => PendingUpload.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[BackgroundUpload] Error loading queue: $e');
      _queue = [];
    }
  }

  Future<void> _saveQueue() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_queueFileName');
      final jsonString =
          jsonEncode(_queue.map((u) => u.toJson()).toList());
      await file.writeAsString(jsonString);
    } catch (e) {
      debugPrint('[BackgroundUpload] Error saving queue: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<Directory> _getUploadsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final uploadsDir = Directory('${dir.path}/$_uploadsDir');
    if (!await uploadsDir.exists()) {
      await uploadsDir.create(recursive: true);
    }
    return uploadsDir;
  }

  Future<void> _deleteUploadFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[BackgroundUpload] Error deleting file $filePath: $e');
    }
  }

  int _getBackoffSeconds(int retryCount) {
    // Exponential backoff: 5s, 15s, 45s
    return 5 * (1 << retryCount);
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    // Find the shortest remaining backoff
    int minWait = 60;
    for (final upload in _queue) {
      if (upload.retryCount >= _maxRetries) continue;
      final backoff = _getBackoffSeconds(upload.retryCount);
      final elapsed = upload.lastRetryAt != null
          ? DateTime.now().difference(upload.lastRetryAt!).inSeconds
          : backoff; // If never retried, process immediately
      final remaining = (backoff - elapsed).clamp(1, 300);
      if (remaining < minWait) minWait = remaining;
    }

    _retryTimer = Timer(Duration(seconds: minWait), () => processQueue());
    debugPrint('[BackgroundUpload] Scheduled retry in ${minWait}s');
  }

  static String _encodeJsonList(List<Map<String, dynamic>> data) =>
      jsonEncode(data);

  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    uploadCompleted.dispose();
  }
}
