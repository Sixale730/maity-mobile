import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recording/recording_state_machine.dart';
import 'package:omi/utils/enums.dart';

void main() {
  late RecordingStateMachine fsm;

  setUp(() {
    fsm = RecordingStateMachine();
  });

  tearDown(() {
    fsm.dispose();
  });

  group('Initial state', () {
    test('starts in stop state', () {
      expect(fsm.state, RecordingState.stop);
    });

    test('isIdle is true initially', () {
      expect(fsm.isIdle, isTrue);
    });

    test('isRecording is false initially', () {
      expect(fsm.isRecording, isFalse);
    });

    test('isInitializing is false initially', () {
      expect(fsm.isInitializing, isFalse);
    });

    test('isPaused is false initially', () {
      expect(fsm.isPaused, isFalse);
    });

    test('session metadata is null initially', () {
      expect(fsm.source, isNull);
      expect(fsm.recordingStartTime, isNull);
      expect(fsm.currentSessionId, isNull);
      expect(fsm.cachedRecordingUserId, isNull);
    });
  });

  group('Valid transitions from stop', () {
    test('stop -> initialising', () {
      expect(fsm.transition(RecordingState.initialising), isTrue);
      expect(fsm.state, RecordingState.initialising);
    });

    test('stop -> record', () {
      expect(fsm.transition(RecordingState.record), isTrue);
      expect(fsm.state, RecordingState.record);
    });

    test('stop -> deviceRecord', () {
      expect(fsm.transition(RecordingState.deviceRecord), isTrue);
      expect(fsm.state, RecordingState.deviceRecord);
    });

    test('stop -> systemAudioRecord', () {
      expect(fsm.transition(RecordingState.systemAudioRecord), isTrue);
      expect(fsm.state, RecordingState.systemAudioRecord);
    });
  });

  group('Valid transitions from initialising', () {
    setUp(() {
      fsm.transition(RecordingState.initialising);
    });

    test('initialising -> record', () {
      expect(fsm.transition(RecordingState.record), isTrue);
      expect(fsm.state, RecordingState.record);
    });

    test('initialising -> deviceRecord', () {
      expect(fsm.transition(RecordingState.deviceRecord), isTrue);
      expect(fsm.state, RecordingState.deviceRecord);
    });

    test('initialising -> systemAudioRecord', () {
      expect(fsm.transition(RecordingState.systemAudioRecord), isTrue);
      expect(fsm.state, RecordingState.systemAudioRecord);
    });

    test('initialising -> stop', () {
      expect(fsm.transition(RecordingState.stop), isTrue);
      expect(fsm.state, RecordingState.stop);
    });

    test('initialising -> error', () {
      expect(fsm.transition(RecordingState.error), isTrue);
      expect(fsm.state, RecordingState.error);
    });
  });

  group('Valid transitions from recording states', () {
    for (final recordingState in [
      RecordingState.record,
      RecordingState.deviceRecord,
      RecordingState.systemAudioRecord,
    ]) {
      group('from ${recordingState.name}', () {
        setUp(() {
          fsm.transition(recordingState);
        });

        test('-> stop', () {
          expect(fsm.transition(RecordingState.stop), isTrue);
          expect(fsm.state, RecordingState.stop);
        });

        test('-> pause', () {
          expect(fsm.transition(RecordingState.pause), isTrue);
          expect(fsm.state, RecordingState.pause);
        });

        test('-> error', () {
          expect(fsm.transition(RecordingState.error), isTrue);
          expect(fsm.state, RecordingState.error);
        });
      });
    }
  });

  group('Valid transitions from pause', () {
    setUp(() {
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.pause);
    });

    test('pause -> record', () {
      expect(fsm.transition(RecordingState.record), isTrue);
      expect(fsm.state, RecordingState.record);
    });

    test('pause -> deviceRecord', () {
      expect(fsm.transition(RecordingState.deviceRecord), isTrue);
      expect(fsm.state, RecordingState.deviceRecord);
    });

    test('pause -> systemAudioRecord', () {
      expect(fsm.transition(RecordingState.systemAudioRecord), isTrue);
      expect(fsm.state, RecordingState.systemAudioRecord);
    });

    test('pause -> stop', () {
      expect(fsm.transition(RecordingState.stop), isTrue);
      expect(fsm.state, RecordingState.stop);
    });
  });

  group('Valid transitions from error', () {
    setUp(() {
      fsm.transition(RecordingState.initialising);
      fsm.transition(RecordingState.error);
    });

    test('error -> stop', () {
      expect(fsm.transition(RecordingState.stop), isTrue);
      expect(fsm.state, RecordingState.stop);
    });

    test('error -> initialising', () {
      expect(fsm.transition(RecordingState.initialising), isTrue);
      expect(fsm.state, RecordingState.initialising);
    });
  });

  group('Invalid transitions', () {
    test('stop -> pause is invalid', () {
      expect(fsm.transition(RecordingState.pause), isFalse);
      expect(fsm.state, RecordingState.stop);
    });

    test('stop -> error is invalid', () {
      expect(fsm.transition(RecordingState.error), isFalse);
      expect(fsm.state, RecordingState.stop);
    });

    test('record -> initialising is invalid', () {
      fsm.transition(RecordingState.record);
      expect(fsm.transition(RecordingState.initialising), isFalse);
      expect(fsm.state, RecordingState.record);
    });

    test('record -> deviceRecord is invalid', () {
      fsm.transition(RecordingState.record);
      expect(fsm.transition(RecordingState.deviceRecord), isFalse);
      expect(fsm.state, RecordingState.record);
    });

    test('error -> record is invalid', () {
      fsm.transition(RecordingState.initialising);
      fsm.transition(RecordingState.error);
      expect(fsm.transition(RecordingState.record), isFalse);
      expect(fsm.state, RecordingState.error);
    });

    test('pause -> error is invalid', () {
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.pause);
      expect(fsm.transition(RecordingState.error), isFalse);
      expect(fsm.state, RecordingState.pause);
    });

    test('pause -> initialising is invalid', () {
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.pause);
      expect(fsm.transition(RecordingState.initialising), isFalse);
      expect(fsm.state, RecordingState.pause);
    });
  });

  group('No-op transitions (same state)', () {
    test('stop -> stop returns true without changing state', () {
      expect(fsm.transition(RecordingState.stop), isTrue);
      expect(fsm.state, RecordingState.stop);
    });

    test('record -> record returns true without changing state', () {
      fsm.transition(RecordingState.record);
      expect(fsm.transition(RecordingState.record), isTrue);
      expect(fsm.state, RecordingState.record);
    });
  });

  group('ValueNotifier fires on state change', () {
    test('notifies listeners on valid transition', () {
      final states = <RecordingState>[];
      fsm.stateNotifier.addListener(() {
        states.add(fsm.stateNotifier.value);
      });

      fsm.transition(RecordingState.initialising);
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.stop);

      expect(states, [
        RecordingState.initialising,
        RecordingState.record,
        RecordingState.stop,
      ]);
    });

    test('does not notify on invalid transition', () {
      int notifyCount = 0;
      fsm.stateNotifier.addListener(() {
        notifyCount++;
      });

      fsm.transition(RecordingState.pause); // invalid from stop

      expect(notifyCount, 0);
    });

    test('does not notify on same-state no-op', () {
      int notifyCount = 0;
      fsm.stateNotifier.addListener(() {
        notifyCount++;
      });

      fsm.transition(RecordingState.stop); // already stop

      expect(notifyCount, 0);
    });
  });

  group('Phone mic flag', () {
    test('isRecordingWithPhoneMic is true when state is record', () {
      fsm.transition(RecordingState.record);
      expect(fsm.isRecordingWithPhoneMic, isTrue);
    });

    test('isRecordingWithPhoneMic is false for deviceRecord', () {
      fsm.transition(RecordingState.deviceRecord);
      expect(fsm.isRecordingWithPhoneMic, isFalse);
    });

    test('isRecordingWithPhoneMic is false for systemAudioRecord', () {
      fsm.transition(RecordingState.systemAudioRecord);
      expect(fsm.isRecordingWithPhoneMic, isFalse);
    });

    test('isRecordingWithPhoneMic resets to false on stop', () {
      fsm.transition(RecordingState.record);
      expect(fsm.isRecordingWithPhoneMic, isTrue);
      fsm.transition(RecordingState.stop);
      expect(fsm.isRecordingWithPhoneMic, isFalse);
    });
  });

  group('Pause flag', () {
    test('isPaused is true after transitioning to pause', () {
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.pause);
      expect(fsm.isPaused, isTrue);
    });

    test('isPaused is false after resuming to record', () {
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.pause);
      fsm.transition(RecordingState.record);
      expect(fsm.isPaused, isFalse);
    });

    test('isPaused resets on stop', () {
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.pause);
      fsm.transition(RecordingState.stop);
      expect(fsm.isPaused, isFalse);
    });
  });

  group('isRecording getter', () {
    test('true for record', () {
      fsm.transition(RecordingState.record);
      expect(fsm.isRecording, isTrue);
    });

    test('true for deviceRecord', () {
      fsm.transition(RecordingState.deviceRecord);
      expect(fsm.isRecording, isTrue);
    });

    test('true for systemAudioRecord', () {
      fsm.transition(RecordingState.systemAudioRecord);
      expect(fsm.isRecording, isTrue);
    });

    test('false for stop', () {
      expect(fsm.isRecording, isFalse);
    });

    test('false for initialising', () {
      fsm.transition(RecordingState.initialising);
      expect(fsm.isRecording, isFalse);
    });

    test('false for pause', () {
      fsm.transition(RecordingState.record);
      fsm.transition(RecordingState.pause);
      expect(fsm.isRecording, isFalse);
    });

    test('false for error', () {
      fsm.transition(RecordingState.initialising);
      fsm.transition(RecordingState.error);
      expect(fsm.isRecording, isFalse);
    });
  });

  group('startSession / endSession', () {
    test('startSession populates metadata', () {
      fsm.startSession(
        source: RecordingSource.phoneMic,
        sessionId: 'session-1',
        userId: 'user-1',
      );

      expect(fsm.source, RecordingSource.phoneMic);
      expect(fsm.currentSessionId, 'session-1');
      expect(fsm.cachedRecordingUserId, 'user-1');
      expect(fsm.recordingStartTime, isNotNull);
      expect(fsm.conversationFinalized, isFalse);
      expect(fsm.finalizeInProgress, isFalse);
    });

    test('startSession resets finalize flags', () {
      fsm.conversationFinalized = true;
      fsm.finalizeInProgress = true;

      fsm.startSession(
        source: RecordingSource.bleDevice,
        sessionId: 'session-2',
      );

      expect(fsm.conversationFinalized, isFalse);
      expect(fsm.finalizeInProgress, isFalse);
    });

    test('startSession without userId leaves it null', () {
      fsm.startSession(
        source: RecordingSource.systemAudio,
        sessionId: 'session-3',
      );

      expect(fsm.cachedRecordingUserId, isNull);
    });

    test('endSession clears all metadata', () {
      fsm.startSession(
        source: RecordingSource.phoneMic,
        sessionId: 'session-1',
        userId: 'user-1',
      );
      fsm.transition(RecordingState.record);

      fsm.endSession();

      expect(fsm.source, isNull);
      expect(fsm.recordingStartTime, isNull);
      expect(fsm.currentSessionId, isNull);
      expect(fsm.cachedRecordingUserId, isNull);
      expect(fsm.conversationFinalized, isFalse);
      expect(fsm.finalizeInProgress, isFalse);
      expect(fsm.isRecordingWithPhoneMic, isFalse);
      expect(fsm.isPaused, isFalse);
    });
  });

  group('Speech profile mode', () {
    test('enterSpeechProfileMode sets flag', () {
      fsm.enterSpeechProfileMode();
      expect(fsm.isSpeechProfileMode, isTrue);
    });

    test('exitSpeechProfileMode clears flag', () {
      fsm.enterSpeechProfileMode();
      fsm.exitSpeechProfileMode();
      expect(fsm.isSpeechProfileMode, isFalse);
    });
  });

  group('reset', () {
    test('reset returns to initial state', () {
      // Set up a complex state
      fsm.transition(RecordingState.record);
      fsm.startSession(
        source: RecordingSource.phoneMic,
        sessionId: 'session-1',
        userId: 'user-1',
      );
      fsm.enterSpeechProfileMode();
      fsm.shouldAutoResumeAfterWake = false;

      fsm.reset();

      expect(fsm.state, RecordingState.stop);
      expect(fsm.isIdle, isTrue);
      expect(fsm.isRecording, isFalse);
      expect(fsm.source, isNull);
      expect(fsm.currentSessionId, isNull);
      expect(fsm.cachedRecordingUserId, isNull);
      expect(fsm.recordingStartTime, isNull);
      expect(fsm.isSpeechProfileMode, isFalse);
      expect(fsm.shouldAutoResumeAfterWake, isTrue);
      expect(fsm.isRecordingWithPhoneMic, isFalse);
      expect(fsm.isPaused, isFalse);
      expect(fsm.conversationFinalized, isFalse);
      expect(fsm.finalizeInProgress, isFalse);
    });
  });

  group('Full recording lifecycle', () {
    test('phone mic: init -> record -> pause -> record -> stop', () {
      expect(fsm.transition(RecordingState.initialising), isTrue);
      expect(fsm.isInitializing, isTrue);

      fsm.startSession(
        source: RecordingSource.phoneMic,
        sessionId: 'sess-1',
        userId: 'uid-1',
      );

      expect(fsm.transition(RecordingState.record), isTrue);
      expect(fsm.isRecording, isTrue);
      expect(fsm.isRecordingWithPhoneMic, isTrue);

      expect(fsm.transition(RecordingState.pause), isTrue);
      expect(fsm.isPaused, isTrue);
      expect(fsm.isRecording, isFalse);

      expect(fsm.transition(RecordingState.record), isTrue);
      expect(fsm.isPaused, isFalse);
      expect(fsm.isRecording, isTrue);

      expect(fsm.transition(RecordingState.stop), isTrue);
      expect(fsm.isIdle, isTrue);
      expect(fsm.isRecordingWithPhoneMic, isFalse);
    });

    test('BLE device: init -> deviceRecord -> error -> stop', () {
      expect(fsm.transition(RecordingState.initialising), isTrue);

      fsm.startSession(
        source: RecordingSource.bleDevice,
        sessionId: 'sess-2',
      );

      expect(fsm.transition(RecordingState.deviceRecord), isTrue);
      expect(fsm.isRecording, isTrue);
      expect(fsm.isRecordingWithPhoneMic, isFalse);

      expect(fsm.transition(RecordingState.error), isTrue);
      expect(fsm.isRecording, isFalse);

      expect(fsm.transition(RecordingState.stop), isTrue);
      expect(fsm.isIdle, isTrue);
    });
  });
}
