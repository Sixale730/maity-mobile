import 'package:flutter/widgets.dart';

/// Stable GlobalKey cache keyed by transcript segment ID.
///
/// Replaces the O(n) `List.generate(n, (_) => GlobalKey())` pattern in
/// [TranscriptWidget] that re-created all keys on every rebuild when
/// the segment count changed. With this cache, keys are created once per
/// segment and reused across rebuilds — O(1) per segment lookup.
class SegmentKeyCache {
  final Map<String, GlobalKey> _cache = {};

  /// Get the GlobalKey for [segmentId], creating one if it doesn't exist.
  GlobalKey getOrCreate(String segmentId) {
    return _cache.putIfAbsent(segmentId, () => GlobalKey());
  }

  /// Remove keys for segment IDs no longer in [activeIds].
  ///
  /// Call periodically (e.g. in `didUpdateWidget`) to prevent unbounded
  /// growth when segments are archived or removed from the active list.
  void pruneExcept(Set<String> activeIds) {
    _cache.removeWhere((id, _) => !activeIds.contains(id));
  }

  int get length => _cache.length;

  void clear() => _cache.clear();
}
