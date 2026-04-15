import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'package:omi/services/local_stt/model_manifest.dart';

/// Device classification based on available RAM.
enum DeviceTier { high, mid, low }

/// Lightweight service for runtime RAM detection and device tier classification.
///
/// Android reads `/proc/meminfo` for actual available RAM.
/// iOS uses a static device-model heuristic (no `/proc/meminfo` available).
/// Desktop defaults to [DeviceTier.high].
///
/// Call [initialize] once at app startup. After that, use the cached
/// [cachedTier] and [cachedThreadCount] getters (sync, safe for non-async callers).
class DeviceMemoryService {
  static DeviceTier? _cachedTier;
  static int? _cachedThreads;
  static int? _cachedQueueCap;

  /// Minimum RAM (MB) to start local STT recording.
  static const int minRamForRecordingMb = 500;

  // ---------------------------------------------------------------------------
  // Lazy-cached API (sync getters for non-async callers)
  // ---------------------------------------------------------------------------

  /// Initialize tier detection. Call once at app startup.
  static Future<void> initialize() async {
    _cachedTier = await getDeviceTier();
    _cachedThreads = threadsForTier(_cachedTier!);
    _cachedQueueCap = queueCapForTier(_cachedTier!);
    debugPrint('[DeviceMemory] Tier: $_cachedTier, '
        'threads: $_cachedThreads, queueCap: $_cachedQueueCap');
  }

  /// Cached thread count (falls back to 2 if not initialized).
  static int get cachedThreadCount => _cachedThreads ?? 2;

  /// Cached tier (falls back to [DeviceTier.mid] if not initialized).
  static DeviceTier get cachedTier => _cachedTier ?? DeviceTier.mid;

  /// Cached queue cap (falls back to 100 if not initialized).
  static int get cachedQueueCap => _cachedQueueCap ?? 100;

  // ---------------------------------------------------------------------------
  // RAM detection
  // ---------------------------------------------------------------------------

  /// Detect available RAM in MB.
  ///
  /// - Android: reads `/proc/meminfo` MemAvailable (actual free RAM).
  /// - iOS: device-model heuristic via [ParakeetModelManifest.lowRamModels].
  /// - Desktop: returns 8192 (assumed high-RAM).
  static Future<int> getAvailableRamMb() async {
    if (Platform.isAndroid) {
      try {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(meminfo);
        if (match != null) return int.parse(match.group(1)!) ~/ 1024;
      } catch (_) {}
      return 2048; // fallback: assume 2GB
    }

    if (Platform.isIOS) {
      try {
        final info = await DeviceInfoPlugin().iosInfo;
        final model = info.utsname.machine;
        if (ParakeetModelManifest.lowRamModels.contains(model)) return 1500;
      } catch (_) {}
      return 4096; // modern iPhones have 6GB+
    }

    return 8192; // desktop
  }

  // ---------------------------------------------------------------------------
  // Tier classification
  // ---------------------------------------------------------------------------

  /// Classify device into tier based on available RAM.
  static Future<DeviceTier> getDeviceTier() async {
    final ramMb = await getAvailableRamMb();
    if (ramMb >= 4096) return DeviceTier.high;
    if (ramMb >= 2048) return DeviceTier.mid;
    return DeviceTier.low;
  }

  /// Recommended thread count per tier.
  static int threadsForTier(DeviceTier tier) => switch (tier) {
        DeviceTier.high => 4,
        DeviceTier.mid => 3,
        DeviceTier.low => 2,
      };

  /// Max queue depth per tier.
  static int queueCapForTier(DeviceTier tier) => switch (tier) {
        DeviceTier.high => 200,
        DeviceTier.mid => 100,
        DeviceTier.low => 50,
      };

  /// Pre-flight gate before starting a recording. Refreshes RAM reading
  /// live (not the cached tier) because the tier is set once at app start
  /// and may not reflect current conditions hours later.
  ///
  /// Returns `canStart: false` when the device has less than
  /// [minRamForRecordingMb] MB free. The caller is expected to surface a
  /// user-visible message and abort the session.
  static Future<({bool canStart, int availableMb})> canStartRecording() async {
    final availableMb = await getAvailableRamMb();
    final ok = availableMb >= minRamForRecordingMb;
    debugPrint('[DeviceMemory] Pre-flight: ${availableMb}MB free, '
        'minimum ${minRamForRecordingMb}MB — canStart=$ok');
    return (canStart: ok, availableMb: availableMb);
  }
}
