/// States for the VAD state machine.
///
/// State transitions:
/// - silence -> preRoll (on speech detected)
/// - preRoll -> speech (after flushing buffer)
/// - speech -> hangOver (on silence detected)
/// - hangOver -> silence (after timeout)
/// - hangOver -> speech (if speech resumes)
enum VadState {
  /// No speech detected, only buffering pre-roll frames.
  /// Audio is NOT sent to the transcription service.
  silence,

  /// Speech just detected, flushing pre-roll buffer.
  /// Pre-roll buffer is being sent to the transcription service.
  preRoll,

  /// Active speech - sending all audio.
  /// All audio is sent to the transcription service.
  speech,

  /// Speech ended, waiting for hang-over timeout.
  /// Audio continues to be sent to capture word endings.
  hangOver,
}

extension VadStateExtension on VadState {
  /// Returns true if audio should be sent in this state
  bool get shouldSendAudio {
    switch (this) {
      case VadState.silence:
        return false;
      case VadState.preRoll:
      case VadState.speech:
      case VadState.hangOver:
        return true;
    }
  }

  /// Human-readable name for logging
  String get displayName {
    switch (this) {
      case VadState.silence:
        return 'Silence';
      case VadState.preRoll:
        return 'Pre-Roll';
      case VadState.speech:
        return 'Speech';
      case VadState.hangOver:
        return 'Hang-Over';
    }
  }
}
