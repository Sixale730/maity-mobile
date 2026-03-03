import 'package:flutter/foundation.dart';
import 'package:omi/utils/enums.dart';

/// Source of the current recording.
enum RecordingSource { phoneMic, bleDevice, systemAudio }

/// Formal FSM for recording states with validated transitions.
/// Prevents invalid state changes and exposes reactive state via ValueNotifier.
class RecordingStateMachine {
  /// Reactive notifier for UI binding.
  final ValueNotifier<RecordingState> stateNotifier =
      ValueNotifier(RecordingState.stop);

  RecordingState get state => stateNotifier.value;

  // ---------------------------------------------------------------------------
  // Recording metadata
  // ---------------------------------------------------------------------------

  RecordingSource? _source;
  RecordingSource? get source => _source;

  DateTime? _recordingStartTime;
  DateTime? get recordingStartTime => _recordingStartTime;

  String? _currentSessionId;
  String? get currentSessionId => _currentSessionId;

  String? _cachedRecordingUserId;
  String? get cachedRecordingUserId => _cachedRecordingUserId;

  // ---------------------------------------------------------------------------
  // Flags
  // ---------------------------------------------------------------------------

  bool _isRecordingWithPhoneMic = false;
  bool get isRecordingWithPhoneMic => _isRecordingWithPhoneMic;

  bool _isPaused = false;
  bool get isPaused => _isPaused;

  bool _shouldAutoResumeAfterWake = true;
  bool get shouldAutoResumeAfterWake => _shouldAutoResumeAfterWake;
  set shouldAutoResumeAfterWake(bool value) => _shouldAutoResumeAfterWake = value;

  bool _isSpeechProfileMode = false;
  bool get isSpeechProfileMode => _isSpeechProfileMode;

  bool _conversationFinalized = false;
  bool get conversationFinalized => _conversationFinalized;
  set conversationFinalized(bool value) => _conversationFinalized = value;

  bool _finalizeInProgress = false;
  bool get finalizeInProgress => _finalizeInProgress;
  set finalizeInProgress(bool value) => _finalizeInProgress = value;

  // ---------------------------------------------------------------------------
  // Convenience getters
  // ---------------------------------------------------------------------------

  bool get isRecording =>
      state == RecordingState.record ||
      state == RecordingState.deviceRecord ||
      state == RecordingState.systemAudioRecord;

  bool get isIdle => state == RecordingState.stop;

  bool get isInitializing => state == RecordingState.initialising;

  // ---------------------------------------------------------------------------
  // Transition table
  // ---------------------------------------------------------------------------

  static final Map<RecordingState, Set<RecordingState>> _validTransitions = {
    RecordingState.stop: {
      RecordingState.initialising,
      RecordingState.record,
      RecordingState.deviceRecord,
      RecordingState.systemAudioRecord,
    },
    RecordingState.initialising: {
      RecordingState.record,
      RecordingState.deviceRecord,
      RecordingState.systemAudioRecord,
      RecordingState.stop,
      RecordingState.error,
    },
    RecordingState.record: {
      RecordingState.stop,
      RecordingState.pause,
      RecordingState.error,
    },
    RecordingState.deviceRecord: {
      RecordingState.stop,
      RecordingState.pause,
      RecordingState.error,
    },
    RecordingState.systemAudioRecord: {
      RecordingState.stop,
      RecordingState.pause,
      RecordingState.error,
    },
    RecordingState.pause: {
      RecordingState.record,
      RecordingState.deviceRecord,
      RecordingState.systemAudioRecord,
      RecordingState.stop,
    },
    RecordingState.error: {
      RecordingState.stop,
      RecordingState.initialising,
    },
  };

  // ---------------------------------------------------------------------------
  // Transition logic
  // ---------------------------------------------------------------------------

  /// Attempt a state transition. Returns true if valid, false if rejected.
  bool transition(RecordingState newState) {
    if (state == newState) return true; // no-op

    final validTargets = _validTransitions[state];
    if (validTargets == null || !validTargets.contains(newState)) {
      debugPrint(
          '[RecordingFSM] Invalid transition: ${state.name} -> ${newState.name}');
      return false;
    }

    debugPrint('[RecordingFSM] Transition: ${state.name} -> ${newState.name}');
    stateNotifier.value = newState;

    // Derive phone-mic flag from state
    if (newState == RecordingState.record) {
      _isRecordingWithPhoneMic = true;
    } else if (newState == RecordingState.stop) {
      _isRecordingWithPhoneMic = false;
      _isPaused = false;
    }

    // Derive pause flag from state
    if (newState == RecordingState.pause) {
      _isPaused = true;
    } else if (isRecording) {
      _isPaused = false;
    }

    return true;
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  /// Start a new recording session. Call this right before/after transitioning
  /// into a recording state to capture metadata for the session.
  void startSession({
    required RecordingSource source,
    required String sessionId,
    String? userId,
  }) {
    _source = source;
    _recordingStartTime = DateTime.now();
    _currentSessionId = sessionId;
    _cachedRecordingUserId = userId;
    _conversationFinalized = false;
    _finalizeInProgress = false;
  }

  /// End the current recording session and clear metadata.
  void endSession() {
    _source = null;
    _recordingStartTime = null;
    _currentSessionId = null;
    _cachedRecordingUserId = null;
    _conversationFinalized = false;
    _finalizeInProgress = false;
    _isRecordingWithPhoneMic = false;
    _isPaused = false;
  }

  // ---------------------------------------------------------------------------
  // Speech profile mode
  // ---------------------------------------------------------------------------

  void enterSpeechProfileMode() {
    _isSpeechProfileMode = true;
  }

  void exitSpeechProfileMode() {
    _isSpeechProfileMode = false;
  }

  // ---------------------------------------------------------------------------
  // Reset
  // ---------------------------------------------------------------------------

  /// Reset all state to initial values.
  void reset() {
    stateNotifier.value = RecordingState.stop;
    endSession();
    _isSpeechProfileMode = false;
    _shouldAutoResumeAfterWake = true;
  }

  void dispose() {
    stateNotifier.dispose();
  }
}
