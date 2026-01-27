import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'vad_config.dart';
import 'vad_state.dart';
import 'vad_metrics.dart';

/// Voice Activity Detection (VAD) service using energy-based detection.
///
/// Filters silence from audio before sending to transcription service,
/// reducing costs by ~40-70% in typical conversations.
///
/// This implementation uses an adaptive energy threshold algorithm:
/// - Calculates RMS energy of each audio frame
/// - Compares against an adaptive threshold
/// - Uses pre-roll buffer to capture speech beginnings
/// - Uses hang-over time to capture speech endings
///
/// Usage:
/// ```dart
/// final vad = VadService(config: vadConfig);
/// await vad.initialize();
/// vad.onAudioToSend = (bytes) => socket.send(bytes);
/// // In audio stream handler:
/// vad.processAudioFrame(audioBytes);
/// // When done:
/// vad.flush();
/// await vad.dispose();
/// ```
class VadService {
  /// Configuration
  final VadConfig config;

  /// Current state
  VadState _state = VadState.silence;
  VadState get state => _state;

  /// Pre-roll circular buffer (stores recent frames before speech detected)
  final Queue<Uint8List> _preRollBuffer = Queue<Uint8List>();

  /// Maximum frames in pre-roll buffer (based on preRollMs / 32ms per frame)
  late final int _maxPreRollFrames;

  /// Timer for hang-over (silence after speech)
  Timer? _hangOverTimer;

  /// Timer for minimum speech duration
  Timer? _minSpeechTimer;
  bool _minSpeechMet = false;

  /// Metrics for tracking savings
  final VadMetrics metrics = VadMetrics();

  /// Callback when audio should be sent to transcription
  void Function(Uint8List)? onAudioToSend;

  /// Callback when VAD state changes (for UI updates)
  void Function(VadState)? onStateChanged;

  /// Whether the service is initialized
  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// Whether the service has been disposed
  bool _disposed = false;

  /// Adaptive noise floor tracking
  double _noiseFloor = 0.01; // Initial noise floor estimate
  double _peakEnergy = 0.1; // Initial peak energy estimate
  static const double _noiseFloorDecay = 0.995; // Slow decay for noise floor
  static const double _peakDecay = 0.99; // Faster decay for peak energy
  static const double _noiseFloorAttack = 0.1; // How fast noise floor rises
  static const double _peakAttack = 0.3; // How fast peak rises

  VadService({required this.config}) {
    // Calculate max pre-roll frames: preRollMs / 32ms per frame
    _maxPreRollFrames = (config.preRollMs / 32).ceil();
  }

  /// Initialize the VAD service
  Future<void> initialize() async {
    if (_disposed) {
      debugPrint('[VAD] Cannot initialize disposed service');
      return;
    }

    if (_initialized) {
      debugPrint('[VAD] Already initialized');
      return;
    }

    debugPrint('[VAD] Initializing energy-based VAD...');
    debugPrint('[VAD] Config: $config');
    debugPrint('[VAD] Max pre-roll frames: $_maxPreRollFrames');

    _initialized = true;
    metrics.reset();
    _state = VadState.silence;

    debugPrint('[VAD] Initialized successfully');
  }

  /// Process an audio frame (expects 512 samples of PCM16 at 16kHz = 1024 bytes).
  /// Returns true if the frame was sent to transcription.
  bool processAudioFrame(Uint8List frame) {
    if (!_initialized || _disposed) {
      // Fallback: send all audio if VAD not working
      onAudioToSend?.call(frame);
      return true;
    }

    try {
      // Calculate energy and detect speech
      final energy = _calculateRmsEnergy(frame);
      final isSpeech = _detectSpeech(energy);

      // Update adaptive thresholds
      _updateAdaptiveThresholds(energy, isSpeech);

      // State machine logic
      switch (_state) {
        case VadState.silence:
          _handleSilenceState(frame, isSpeech);
          break;
        case VadState.preRoll:
          _handlePreRollState(frame, isSpeech);
          break;
        case VadState.speech:
          _handleSpeechState(frame, isSpeech);
          break;
        case VadState.hangOver:
          _handleHangOverState(frame, isSpeech);
          break;
      }

      // Record metrics
      final sent = _state.shouldSendAudio;
      metrics.recordFrame(sent: sent);

      return sent;
    } catch (e) {
      debugPrint('[VAD] Error processing frame: $e');
      // Fallback: send all audio on error
      onAudioToSend?.call(frame);
      metrics.recordFrame(sent: true);
      return true;
    }
  }

  /// Calculate RMS (Root Mean Square) energy of an audio frame
  double _calculateRmsEnergy(Uint8List frame) {
    if (frame.length < 2) return 0.0;

    final numSamples = frame.length ~/ 2;
    final byteData = ByteData.sublistView(frame);

    double sumSquares = 0.0;
    for (var i = 0; i < numSamples; i++) {
      // Read as signed 16-bit little-endian
      final sample = byteData.getInt16(i * 2, Endian.little);
      // Normalize to [-1, 1]
      final normalized = sample / 32768.0;
      sumSquares += normalized * normalized;
    }

    return sqrt(sumSquares / numSamples);
  }

  /// Detect speech using adaptive threshold
  bool _detectSpeech(double energy) {
    // Calculate dynamic threshold based on noise floor and peak
    // Threshold is positioned between noise floor and peak
    // speechThreshold config value (0-1) controls where in this range
    final range = _peakEnergy - _noiseFloor;
    final threshold = _noiseFloor + (range * config.speechThreshold);

    // Add a minimum threshold to avoid false positives in complete silence
    final effectiveThreshold = max(threshold, 0.005);

    return energy > effectiveThreshold;
  }

  /// Update adaptive noise floor and peak energy estimates
  void _updateAdaptiveThresholds(double energy, bool isSpeech) {
    if (isSpeech) {
      // During speech, update peak energy (with attack/decay)
      if (energy > _peakEnergy) {
        _peakEnergy = _peakEnergy * (1 - _peakAttack) + energy * _peakAttack;
      } else {
        _peakEnergy = _peakEnergy * _peakDecay;
      }
      // Ensure peak doesn't fall below noise floor
      _peakEnergy = max(_peakEnergy, _noiseFloor * 2);
    } else {
      // During silence, update noise floor
      if (energy < _noiseFloor) {
        // Quick drop
        _noiseFloor = energy;
      } else if (energy < _noiseFloor * 2) {
        // Slow rise for noise floor
        _noiseFloor = _noiseFloor * (1 - _noiseFloorAttack) + energy * _noiseFloorAttack;
      }
      // Decay noise floor slowly (in case environment gets quieter)
      _noiseFloor = _noiseFloor * _noiseFloorDecay;
      // Ensure noise floor doesn't go to zero
      _noiseFloor = max(_noiseFloor, 0.001);
    }
  }

  /// Handle silence state
  void _handleSilenceState(Uint8List frame, bool isSpeech) {
    // Add to pre-roll buffer (circular)
    _preRollBuffer.addLast(Uint8List.fromList(frame));
    if (_preRollBuffer.length > _maxPreRollFrames) {
      _preRollBuffer.removeFirst();
    }

    if (isSpeech) {
      // Speech detected - transition to preRoll
      _changeState(VadState.preRoll);
      _startMinSpeechTimer();
      metrics.recordSpeechSegmentStart();

      // Flush pre-roll buffer
      _flushPreRollBuffer();
    }
  }

  /// Handle preRoll state
  void _handlePreRollState(Uint8List frame, bool isSpeech) {
    // Send the current frame
    onAudioToSend?.call(frame);

    // Clear pre-roll buffer since we've flushed it
    _preRollBuffer.clear();

    // Transition to speech state
    _changeState(VadState.speech);
  }

  /// Handle speech state
  void _handleSpeechState(Uint8List frame, bool isSpeech) {
    // Always send audio during speech
    onAudioToSend?.call(frame);

    if (!isSpeech && _minSpeechMet) {
      // Silence detected and minimum speech duration met - start hang-over
      _changeState(VadState.hangOver);
      _startHangOverTimer();
    }
  }

  /// Handle hangOver state
  void _handleHangOverState(Uint8List frame, bool isSpeech) {
    // Send audio during hang-over (to capture word endings)
    onAudioToSend?.call(frame);

    if (isSpeech) {
      // Speech resumed - cancel hang-over and go back to speech
      _cancelHangOverTimer();
      _changeState(VadState.speech);
    }
    // If still silence, timer will handle transition
  }

  /// Change state and notify
  void _changeState(VadState newState) {
    if (_state != newState) {
      debugPrint('[VAD] State: ${_state.displayName} -> ${newState.displayName}');
      _state = newState;
      onStateChanged?.call(_state);
    }
  }

  /// Start minimum speech duration timer
  void _startMinSpeechTimer() {
    _minSpeechMet = false;
    _minSpeechTimer?.cancel();
    _minSpeechTimer = Timer(Duration(milliseconds: config.minSpeechMs), () {
      _minSpeechMet = true;
    });
  }

  /// Start hang-over timer
  void _startHangOverTimer() {
    _hangOverTimer?.cancel();
    _hangOverTimer = Timer(Duration(milliseconds: config.hangOverMs), () {
      // Hang-over timeout - transition to silence
      _changeState(VadState.silence);
      _cancelMinSpeechTimer();
    });
  }

  /// Cancel hang-over timer
  void _cancelHangOverTimer() {
    _hangOverTimer?.cancel();
    _hangOverTimer = null;
  }

  /// Cancel minimum speech timer
  void _cancelMinSpeechTimer() {
    _minSpeechTimer?.cancel();
    _minSpeechTimer = null;
    _minSpeechMet = false;
  }

  /// Flush pre-roll buffer to transcription
  void _flushPreRollBuffer() {
    debugPrint('[VAD] Flushing ${_preRollBuffer.length} pre-roll frames');
    for (final frame in _preRollBuffer) {
      onAudioToSend?.call(frame);
    }
    // Note: We don't clear here, it's cleared in preRoll state handler
  }

  /// Flush any remaining audio and reset state
  /// Call this when recording ends
  void flush() {
    debugPrint('[VAD] Flushing. Final metrics: $metrics');

    // If in speech or hang-over, we've already sent the audio
    // If in silence, there's no pending audio to send

    // Cancel timers
    _cancelHangOverTimer();
    _cancelMinSpeechTimer();

    // Reset state
    _preRollBuffer.clear();
    _changeState(VadState.silence);
  }

  /// Reset for a new conversation
  void reset() {
    flush();
    metrics.reset();
    // Reset adaptive thresholds
    _noiseFloor = 0.01;
    _peakEnergy = 0.1;
    debugPrint('[VAD] Reset for new conversation');
  }

  /// Dispose the VAD service
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    debugPrint('[VAD] Disposing. Final metrics: $metrics');

    _cancelHangOverTimer();
    _cancelMinSpeechTimer();
    _preRollBuffer.clear();

    _initialized = false;
  }

  /// Get a snapshot of current metrics
  VadMetrics getMetricsSnapshot() {
    return metrics.copy();
  }
}
