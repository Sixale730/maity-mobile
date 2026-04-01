import 'dart:async';

import 'package:flutter/foundation.dart';

import 'device_connection.dart';

/// Oscillates LED brightness via BLE to create a "breathing" visual pulse
/// while a recording is paused on the OMI wearable.
class LedBreathingService {
  static const _stepInterval = Duration(milliseconds: 700);

  Timer? _timer;
  int? _savedDimRatio;
  DeviceConnection? _connection;
  bool _isWriting = false;
  bool _isOn = false;

  bool get isActive => _timer != null;

  /// Start the breathing animation.
  /// Reads and saves the current dim ratio, then begins oscillating.
  Future<void> start(DeviceConnection connection) async {
    if (_timer != null) return; // already active

    _connection = connection;
    _isOn = false;

    // Save original brightness to restore later
    try {
      _savedDimRatio = await connection.getLedDimRatio();
    } catch (e) {
      debugPrint('[LedBreathing] Failed to read current dim ratio: $e');
      _savedDimRatio = null;
    }

    _timer = Timer.periodic(_stepInterval, _tick);
    debugPrint('[LedBreathing] Started (saved ratio: $_savedDimRatio)');
  }

  /// Stop the animation and restore the original dim ratio.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _isWriting = false;

    // Restore original brightness
    if (_connection != null && _savedDimRatio != null) {
      try {
        await _connection!.setLedDimRatio(_savedDimRatio!);
        debugPrint('[LedBreathing] Restored dim ratio to $_savedDimRatio');
      } catch (e) {
        debugPrint('[LedBreathing] Failed to restore dim ratio: $e');
      }
    }

    _connection = null;
    _savedDimRatio = null;
  }

  /// Cancel the animation without BLE write (e.g. device disconnected).
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _connection = null;
    _savedDimRatio = null;
    _isWriting = false;
  }

  void dispose() {
    cancel();
  }

  void _tick(Timer timer) async {
    final conn = _connection;
    if (conn == null || _isWriting) return;

    _isOn = !_isOn;
    final brightness = _isOn ? 100 : 0;

    _isWriting = true;
    try {
      await conn.setLedDimRatio(brightness);
      debugPrint('[LedBreathing] Wrote brightness: $brightness');
    } catch (e) {
      debugPrint('[LedBreathing] Write failed: $e');
    } finally {
      _isWriting = false;
    }
  }
}
