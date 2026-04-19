import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:omi/services/recording/session_snapshot.dart';

/// Phase of the session lifecycle FSM.
///
/// ```
/// idle → active
/// active → stopping, idle (cancelNoSegments)
/// stopping → finalizing
/// finalizing → restarting, idle
/// restarting → active, idle
/// ```
enum SessionPhase { idle, active, stopping, finalizing, restarting }

/// Manages the high-level lifecycle of a recording session.
///
/// Complements [RecordingStateMachine] (which tracks audio-transport state)
/// by modelling the *session* phases: active recording → stopping → snapshot
/// capture → finalization → optional restart.
///
/// Key responsibilities:
/// - Validated phase transitions via a static transition table.
/// - Holds the [SessionSnapshot] captured at stop time.
/// - Tracks the last audio-received timestamp (for local STT silence
///   detection).
/// - Derives deterministic idempotency keys from session IDs.
class SessionLifecycleManager {
  // ---------------------------------------------------------------------------
  // Reactive state
  // ---------------------------------------------------------------------------

  /// Reactive notifier for UI binding.
  final ValueNotifier<SessionPhase> phaseNotifier =
      ValueNotifier(SessionPhase.idle);

  SessionPhase get phase => phaseNotifier.value;

  // ---------------------------------------------------------------------------
  // Transition table
  // ---------------------------------------------------------------------------

  static final Map<SessionPhase, Set<SessionPhase>> _validTransitions = {
    SessionPhase.idle: {SessionPhase.active},
    SessionPhase.active: {SessionPhase.stopping, SessionPhase.idle},
    SessionPhase.stopping: {SessionPhase.finalizing},
    SessionPhase.finalizing: {SessionPhase.restarting, SessionPhase.idle},
    SessionPhase.restarting: {SessionPhase.active, SessionPhase.idle},
  };

  // ---------------------------------------------------------------------------
  // Transition logic
  // ---------------------------------------------------------------------------

  /// Attempt a phase transition. Returns true if valid, false if rejected.
  bool transition(SessionPhase newPhase) {
    if (phase == newPhase) return true; // no-op

    final validTargets = _validTransitions[phase];
    if (validTargets == null || !validTargets.contains(newPhase)) {
      debugPrint(
          '[SessionLifecycle] Invalid transition: ${phase.name} -> ${newPhase.name}');
      return false;
    }

    debugPrint(
        '[SessionLifecycle] Transition: ${phase.name} -> ${newPhase.name}');
    phaseNotifier.value = newPhase;
    return true;
  }

  // ---------------------------------------------------------------------------
  // Session snapshot
  // ---------------------------------------------------------------------------

  SessionSnapshot? _currentSnapshot;

  /// The snapshot captured during the stopping phase, or null if no session
  /// has been stopped yet (or after [reset]).
  SessionSnapshot? get currentSnapshot => _currentSnapshot;

  /// Store a snapshot (called during the stopping → finalizing transition).
  void setSnapshot(SessionSnapshot snapshot) {
    _currentSnapshot = snapshot;
  }

  // ---------------------------------------------------------------------------
  // Audio-flow tracking
  // ---------------------------------------------------------------------------

  DateTime? _lastAudioReceivedAt;

  /// Timestamp of the last audio frame received. Used for local STT silence
  /// detection where the pipeline doesn't have a cloud socket to monitor.
  DateTime? get lastAudioReceivedAt => _lastAudioReceivedAt;

  /// Mark that audio has been received right now.
  void markAudioReceived() {
    _lastAudioReceivedAt = DateTime.now();
  }

  // ---------------------------------------------------------------------------
  // Idempotency
  // ---------------------------------------------------------------------------

  static const _uuid = Uuid();

  /// Derive a deterministic idempotency key from a session ID.
  ///
  /// Uses UUID v5 (SHA-1 based) so the same sessionId always produces the
  /// same key — safe for retry deduplication.
  String deriveIdempotencyKey(String sessionId) {
    return _uuid.v5(Namespace.url.value, 'maity:session:$sessionId');
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle helpers
  // ---------------------------------------------------------------------------

  /// Start a new session. Transitions to [SessionPhase.active] and clears
  /// any leftover snapshot / audio tracking from the previous session.
  void startSession() {
    _currentSnapshot = null;
    _lastAudioReceivedAt = null;
    transition(SessionPhase.active);
  }

  /// Reset all state to initial values.
  void reset() {
    phaseNotifier.value = SessionPhase.idle;
    _currentSnapshot = null;
    _lastAudioReceivedAt = null;
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  void dispose() {
    phaseNotifier.dispose();
  }
}
