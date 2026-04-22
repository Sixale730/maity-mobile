import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/services/stt/cloud/transcription_service.dart';

/// High-level health of a recording session, independent of transport details.
///
/// Each STT/recording mode (cloud, local, BLE) reports health via its own
/// [RecordingHealthMonitor] implementation, so consumers (like the background
/// policy) can make decisions without knowing about sockets, IPC ports, or
/// BLE connection state.
enum HealthStatus {
  /// Audio flowing and segments arriving at expected cadence.
  healthy,

  /// Audio flowing but segments delayed — STT catching up after a burst or
  /// temporarily slow inference. Non-fatal.
  degraded,

  /// No audio bytes or segments observed for longer than [stallThreshold].
  /// Recording has effectively stopped producing output.
  stalled,

  /// Unrecoverable — terminal socket error, plugin died, etc.
  /// Local STT never reports this (the on-device engine has no terminal state).
  failed,
}

/// Observes a recording pipeline and reports an abstract [HealthStatus].
///
/// Implementations are provider-specific: they know how to read the right
/// low-level signals (websocket state, IPC audio flow, BLE connection)
/// without leaking those details to callers.
abstract class RecordingHealthMonitor {
  /// Current health snapshot. Cheap to read; recomputed on call.
  HealthStatus get status;

  /// Time since the monitor last observed a healthy signal. Zero if unknown
  /// or if there hasn't been a first signal yet.
  Duration get timeSinceLastSignal;

  /// Stream of status changes. Consumers listen to react to transitions.
  ValueListenable<HealthStatus> get statusNotifier;

  /// Threshold for declaring the recording stalled. Varies per
  /// implementation based on the natural cadence of each transport.
  Duration get stallThreshold;

  /// Clean up listeners/timers. Called when the session ends.
  void dispose();
}

/// Base class with shared ValueNotifier + periodic polling logic.
///
/// Subclasses only implement [_computeStatus]. The base polls every 5 s
/// and emits changes via [statusNotifier].
abstract class _PollingHealthMonitor implements RecordingHealthMonitor {
  _PollingHealthMonitor() {
    _statusNotifier = ValueNotifier(HealthStatus.healthy);
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  late final ValueNotifier<HealthStatus> _statusNotifier;
  Timer? _pollTimer;

  /// Subclass-specific: compute the current status from observed signals.
  HealthStatus _computeStatus();

  /// Subclass-specific: time since the monitor last observed a healthy signal.
  Duration computeTimeSinceLastSignal();

  @override
  HealthStatus get status => _computeStatus();

  @override
  Duration get timeSinceLastSignal => computeTimeSinceLastSignal();

  @override
  ValueListenable<HealthStatus> get statusNotifier => _statusNotifier;

  void _poll() {
    final next = _computeStatus();
    if (_statusNotifier.value != next) {
      _statusNotifier.value = next;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _statusNotifier.dispose();
  }
}

/// Health monitor for cloud STT (Deepgram). Uses the websocket state,
/// last audio bytes sent timestamp, and last segment received timestamp to
/// decide health.
///
/// Replicates the intent of [TranscriptionPipeline._checkSocketHealth]
/// without duplicating its side-effects (this class is observation-only).
class CloudSttHealthMonitor extends _PollingHealthMonitor {
  CloudSttHealthMonitor({
    required DateTime? Function() getLastAudioBytesSentAt,
    required DateTime? Function() getLastSegmentReceivedAt,
    required SocketServiceState? Function() getSocketState,
    required int Function() getSegmentsCount,
  })  : _getLastAudioBytesSentAt = getLastAudioBytesSentAt,
        _getLastSegmentReceivedAt = getLastSegmentReceivedAt,
        _getSocketState = getSocketState,
        _getSegmentsCount = getSegmentsCount,
        _createdAt = DateTime.now();

  final DateTime? Function() _getLastAudioBytesSentAt;
  final DateTime? Function() _getLastSegmentReceivedAt;
  final SocketServiceState? Function() _getSocketState;
  final int Function() _getSegmentsCount;
  final DateTime _createdAt;

  @override
  Duration get stallThreshold => const Duration(seconds: 30);

  static const _disconnectFailureThreshold = Duration(seconds: 60);
  static const _segmentStallThreshold = Duration(seconds: 60);

  DateTime? _firstDisconnectAt;

  @override
  HealthStatus _computeStatus() {
    final socket = _getSocketState();
    final now = DateTime.now();

    // Terminal socket failure after sustained disconnect.
    if (socket != SocketServiceState.connected) {
      _firstDisconnectAt ??= now;
      final disconnectedFor = now.difference(_firstDisconnectAt!);
      if (disconnectedFor > _disconnectFailureThreshold) {
        return HealthStatus.failed;
      }
      return HealthStatus.stalled;
    }
    _firstDisconnectAt = null;

    // Socket up — check audio flow.
    final lastAudio = _getLastAudioBytesSentAt();
    if (lastAudio == null) {
      // No audio flow yet. Give grace period after construction.
      return now.difference(_createdAt) > stallThreshold
          ? HealthStatus.stalled
          : HealthStatus.healthy;
    }
    final audioGap = now.difference(lastAudio);
    if (audioGap > stallThreshold) {
      return HealthStatus.stalled;
    }

    // Socket up, audio flowing — check segment cadence if we have segments.
    if (_getSegmentsCount() > 0) {
      final lastSeg = _getLastSegmentReceivedAt();
      if (lastSeg != null) {
        final segGap = now.difference(lastSeg);
        if (segGap > _segmentStallThreshold) {
          return HealthStatus.degraded;
        }
      }
    }

    return HealthStatus.healthy;
  }

  @override
  Duration computeTimeSinceLastSignal() {
    final last = _getLastAudioBytesSentAt();
    if (last == null) return Duration.zero;
    return DateTime.now().difference(last);
  }
}

/// Health monitor for on-device STT (Parakeet, Moonshine, Canary).
///
/// Ignores socket state deliberately: the "socket" for local STT wraps IPC
/// to the worker isolate and always reports disconnected, which would be a
/// permanent false positive. The true signal is whether audio is flowing
/// into the pipeline — if yes, the mic is alive and the worker will
/// eventually decode it; if no, something is wrong.
class LocalSttHealthMonitor extends _PollingHealthMonitor {
  LocalSttHealthMonitor({
    required DateTime? Function() getLastAudioBytesSentAt,
  })  : _getLastAudioBytesSentAt = getLastAudioBytesSentAt,
        _createdAt = DateTime.now();

  final DateTime? Function() _getLastAudioBytesSentAt;
  final DateTime _createdAt;

  @override
  Duration get stallThreshold => const Duration(seconds: 30);

  @override
  HealthStatus _computeStatus() {
    final now = DateTime.now();
    final lastAudio = _getLastAudioBytesSentAt();

    if (lastAudio == null) {
      // No audio seen yet — grace period after construction.
      return now.difference(_createdAt) > stallThreshold
          ? HealthStatus.stalled
          : HealthStatus.healthy;
    }

    final gap = now.difference(lastAudio);
    if (gap > stallThreshold) return HealthStatus.stalled;
    return HealthStatus.healthy;
  }

  @override
  Duration computeTimeSinceLastSignal() {
    final last = _getLastAudioBytesSentAt();
    if (last == null) return Duration.zero;
    return DateTime.now().difference(last);
  }
}

/// Health monitor for BLE device recording. Checks BLE connection state in
/// addition to audio flow, since a disconnected BLE device means no audio
/// is coming regardless of recent timestamps.
class BleHealthMonitor extends _PollingHealthMonitor {
  BleHealthMonitor({
    required DateTime? Function() getLastAudioBytesSentAt,
    required bool Function() getIsConnected,
  })  : _getLastAudioBytesSentAt = getLastAudioBytesSentAt,
        _getIsConnected = getIsConnected,
        _createdAt = DateTime.now();

  final DateTime? Function() _getLastAudioBytesSentAt;
  final bool Function() _getIsConnected;
  final DateTime _createdAt;

  @override
  Duration get stallThreshold => const Duration(seconds: 30);

  static const _degradedThreshold = Duration(seconds: 10);
  static const _disconnectStallThreshold = Duration(seconds: 10);

  DateTime? _firstDisconnectAt;

  @override
  HealthStatus _computeStatus() {
    final now = DateTime.now();

    if (!_getIsConnected()) {
      _firstDisconnectAt ??= now;
      final disconnectedFor = now.difference(_firstDisconnectAt!);
      if (disconnectedFor > _disconnectStallThreshold) {
        return HealthStatus.stalled;
      }
      return HealthStatus.degraded;
    }
    _firstDisconnectAt = null;

    final lastAudio = _getLastAudioBytesSentAt();
    if (lastAudio == null) {
      return now.difference(_createdAt) > stallThreshold
          ? HealthStatus.stalled
          : HealthStatus.healthy;
    }

    final gap = now.difference(lastAudio);
    if (gap > stallThreshold) return HealthStatus.stalled;
    if (gap > _degradedThreshold) return HealthStatus.degraded;
    return HealthStatus.healthy;
  }

  @override
  Duration computeTimeSinceLastSignal() {
    final last = _getLastAudioBytesSentAt();
    if (last == null) return Duration.zero;
    return DateTime.now().difference(last);
  }
}
