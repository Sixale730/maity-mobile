import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Singleton collector for recording session telemetry.
///
/// Accumulates metrics for a single active recording session and produces
/// snapshots that can be persisted alongside background uploads. Snapshots
/// are sent to `maity.recording_session_telemetry` via the
/// `insert_recording_telemetry` RPC by [TelemetrySender] once the upload
/// completes (or fails permanently).
///
/// Fire-and-forget: never throws. Missing data is reported as null.
class TelemetryCollector {
  TelemetryCollector._();
  static final TelemetryCollector instance = TelemetryCollector._();

  // ---------------------------------------------------------------------------
  // Session state (mutable for the active session only)
  // ---------------------------------------------------------------------------
  String? _sessionId;
  DateTime? _startTime;
  DateTime? _stopTime;
  String? _audioSource; // 'ble' | 'phone_mic' | 'system_audio'
  String? _sttProvider;

  int _segmentsCount = 0;
  int _wordsCount = 0;
  int _reconnectionCount = 0;
  int _bleDisconnects = 0;
  int _errorsCount = 0;
  double _audioGapsSeconds = 0;

  // Audio-gap measurement: when buffering during reconnect, this is the
  // timestamp at which buffering started; closed-out when the socket reconnects.
  DateTime? _gapStartedAt;

  // Latency tracking (avg transcription latency)
  int _latencySamples = 0;
  int _latencySumMs = 0;

  // VAD totals (only populated when VAD service is active)
  int _vadSpeechMs = 0;
  int _vadSilenceMs = 0;

  // Bounded events log for raw_metrics JSON
  final List<Map<String, dynamic>> _events = [];
  static const int _maxEvents = 50;

  // ---------------------------------------------------------------------------
  // App / device context (cached at init, reused across sessions)
  // ---------------------------------------------------------------------------
  String? _cachedAppVersion;
  String? _cachedOsVersion;
  String? _cachedPlatform;
  String? _cachedDeviceModel;

  bool _initStarted = false;

  /// Cache app and device info. Safe to call multiple times.
  /// Fire-and-forget — never throws.
  Future<void> initialize() async {
    if (_initStarted) return;
    _initStarted = true;
    try {
      final pkg = await PackageInfo.fromPlatform();
      _cachedAppVersion = '${pkg.version}+${pkg.buildNumber}';
    } catch (e) {
      debugPrint('[TelemetryCollector] PackageInfo error: $e');
    }
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        _cachedOsVersion = 'Android ${a.version.release}';
        _cachedPlatform = 'android';
        _cachedDeviceModel = a.model;
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        _cachedOsVersion = 'iOS ${i.systemVersion}';
        _cachedPlatform = 'ios';
        _cachedDeviceModel = i.utsname.machine;
      } else if (Platform.isMacOS) {
        final m = await info.macOsInfo;
        _cachedOsVersion = 'macOS ${m.osRelease}';
        _cachedPlatform = 'macos';
        _cachedDeviceModel = m.model;
      } else if (Platform.isWindows) {
        final w = await info.windowsInfo;
        _cachedOsVersion = 'Windows ${w.displayVersion}';
        _cachedPlatform = 'windows';
        _cachedDeviceModel = w.computerName;
      } else if (Platform.isLinux) {
        final l = await info.linuxInfo;
        _cachedOsVersion = 'Linux ${l.version}';
        _cachedPlatform = 'linux';
        _cachedDeviceModel = l.prettyName;
      }
    } catch (e) {
      debugPrint('[TelemetryCollector] DeviceInfo error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  /// Begin a new recording session. Resets all per-session counters.
  void startSession({
    required String sessionId,
    required String audioSource,
    DateTime? startedAt,
    String? sttProvider,
  }) {
    // Lazy init on first session
    initialize();

    _sessionId = sessionId;
    _startTime = startedAt ?? DateTime.now();
    _stopTime = null;
    _audioSource = audioSource;
    _sttProvider = sttProvider;
    _segmentsCount = 0;
    _wordsCount = 0;
    _reconnectionCount = 0;
    _bleDisconnects = 0;
    _errorsCount = 0;
    _audioGapsSeconds = 0;
    _gapStartedAt = null;
    _latencySamples = 0;
    _latencySumMs = 0;
    _vadSpeechMs = 0;
    _vadSilenceMs = 0;
    _events.clear();

    debugPrint(
        '[TelemetryCollector] Session started id=$sessionId source=$audioSource');
  }

  /// Mark the moment the user (or auto-save) stopped the recording.
  /// Idempotent: subsequent calls are no-ops.
  void markStopped() {
    _stopTime ??= DateTime.now();
    // Close out any in-progress audio gap
    _closeAudioGap();
  }

  // ---------------------------------------------------------------------------
  // Per-event hooks
  // ---------------------------------------------------------------------------

  void setSttProvider(String? provider) {
    if (provider == null) return;
    _sttProvider = provider;
  }

  void recordReconnection({String? reason}) {
    _reconnectionCount++;
    _addEvent({'type': 'reconnection', 'reason': reason});
  }

  void recordBleDisconnect({String? reason}) {
    _bleDisconnects++;
    _addEvent({'type': 'ble_disconnect', 'reason': reason});
  }

  void recordError(String type, String message) {
    _errorsCount++;
    _addEvent({
      'type': 'error',
      'error_type': type,
      'message': _truncate(message, 200),
    });
  }

  /// Mark the start of a buffering / disconnected period (cloud STT only).
  void beginAudioGap() {
    _gapStartedAt ??= DateTime.now();
  }

  /// Close the in-progress audio gap and accumulate seconds.
  void endAudioGap() => _closeAudioGap();

  void _closeAudioGap() {
    final start = _gapStartedAt;
    if (start == null) return;
    final gap = DateTime.now().difference(start).inMilliseconds / 1000.0;
    if (gap > 0) _audioGapsSeconds += gap;
    _gapStartedAt = null;
  }

  void recordTranscriptionLatency(int latencyMs) {
    if (latencyMs <= 0) return;
    _latencySamples++;
    _latencySumMs += latencyMs;
  }

  void recordVadSpeech(int ms) {
    if (ms > 0) _vadSpeechMs += ms;
  }

  void recordVadSilence(int ms) {
    if (ms > 0) _vadSilenceMs += ms;
  }

  /// Update segment / word totals. Called on each segment update.
  void updateSegmentMetrics({required int segmentsCount, required int wordsCount}) {
    _segmentsCount = segmentsCount;
    _wordsCount = wordsCount;
  }

  void _addEvent(Map<String, dynamic> ev) {
    ev['at_ms'] = DateTime.now().millisecondsSinceEpoch;
    if (_events.length >= _maxEvents) _events.removeAt(0);
    _events.add(ev);
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  // ---------------------------------------------------------------------------
  // Snapshot
  // ---------------------------------------------------------------------------

  /// Build a JSON-serializable snapshot of the current session metrics.
  /// Caller is responsible for sending it (typically via [TelemetrySender]).
  /// Does NOT mutate or reset state.
  Map<String, dynamic> snapshot() {
    final start = _startTime ?? DateTime.now();
    final stop = _stopTime ?? DateTime.now();
    final durationSeconds = stop.difference(start).inSeconds;

    final avgLatency = _latencySamples > 0
        ? (_latencySumMs / _latencySamples).round()
        : null;
    final totalVadMs = _vadSpeechMs + _vadSilenceMs;
    final vadRatio =
        totalVadMs > 0 ? (_vadSpeechMs / totalVadMs).toDouble() : null;
    final segmentsPerMinute = durationSeconds > 0
        ? (_segmentsCount * 60.0 / durationSeconds)
        : null;

    return {
      'session_id': _sessionId,
      'duration_seconds': durationSeconds,
      'segments_count': _segmentsCount,
      'words_count': _wordsCount,
      'audio_source': _audioSource,
      'device_model': _cachedDeviceModel,
      'stt_provider': _sttProvider,
      'reconnection_count': _reconnectionCount,
      'audio_gaps_seconds': _audioGapsSeconds,
      'ble_disconnects': _bleDisconnects,
      'avg_transcription_latency_ms': avgLatency,
      'vad_speech_ratio': vadRatio,
      'segments_per_minute': segmentsPerMinute,
      'errors_count': _errorsCount,
      'app_version': _cachedAppVersion,
      'os_version': _cachedOsVersion,
      'platform': _cachedPlatform ?? 'unknown',
      'raw_metrics': {
        'timings': {
          'recording_start_ms': start.millisecondsSinceEpoch,
          'recording_stop_ms': stop.millisecondsSinceEpoch,
        },
        'events': List<Map<String, dynamic>>.from(_events),
        'vad': {
          'total_speech_ms': _vadSpeechMs,
          'total_silence_ms': _vadSilenceMs,
        },
      },
    };
  }

  /// Clear all per-session state. Cached app/device info is preserved.
  void reset() {
    _sessionId = null;
    _startTime = null;
    _stopTime = null;
    _audioSource = null;
    _sttProvider = null;
    _segmentsCount = 0;
    _wordsCount = 0;
    _reconnectionCount = 0;
    _bleDisconnects = 0;
    _errorsCount = 0;
    _audioGapsSeconds = 0;
    _gapStartedAt = null;
    _latencySamples = 0;
    _latencySumMs = 0;
    _vadSpeechMs = 0;
    _vadSilenceMs = 0;
    _events.clear();
  }

  // Test / debug accessors
  String? get currentSessionId => _sessionId;
  int get reconnectionCount => _reconnectionCount;
  int get bleDisconnects => _bleDisconnects;
  int get errorsCount => _errorsCount;
}
