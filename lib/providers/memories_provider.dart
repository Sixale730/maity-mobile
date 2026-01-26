import 'dart:async';
import 'package:omi/widgets/extensions/string.dart';
import 'package:omi/backend/http/api/memories.dart';
import 'package:omi/backend/schema/memory.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:tuple/tuple.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class MemoriesProvider extends ChangeNotifier {
  List<Memory> _memories = [];
  List<Memory> _unreviewed = [];
  bool _loading = true;
  String _searchQuery = '';
  MemoryCategory? _categoryFilter;
  bool _excludeInteresting = false;
  List<Tuple2<MemoryCategory, int>> categories = [];
  MemoryCategory? selectedCategory;
  int _pendingReviewCount = 0;

  List<Memory> get memories => _memories;
  List<Memory> get unreviewed => _unreviewed;
  bool get loading => _loading;
  String get searchQuery => _searchQuery;
  MemoryCategory? get categoryFilter => _categoryFilter;
  bool get excludeInteresting => _excludeInteresting;
  int get pendingReviewCount => _pendingReviewCount;

  List<Memory> get filteredMemories {
    return _memories.where((memory) {
      // Apply search filter
      final matchesSearch =
          _searchQuery.isEmpty || memory.content.decodeString.toLowerCase().contains(_searchQuery.toLowerCase());

      // Apply category filter or exclusion logic
      bool categoryMatch;
      if (_excludeInteresting) {
        // Show all categories except interesting
        categoryMatch = memory.category != MemoryCategory.interesting;
      } else if (_categoryFilter != null) {
        // Show only selected category
        categoryMatch = memory.category == _categoryFilter;
      } else {
        // Show all categories if no filter is applied
        categoryMatch = true;
      }

      return matchesSearch && categoryMatch;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void setExcludeInteresting(bool exclude) {
    _excludeInteresting = exclude;
    notifyListeners();
  }

  void setCategory(MemoryCategory? category) {
    selectedCategory = category;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query.toLowerCase();
    notifyListeners();
  }

  void setCategoryFilter(MemoryCategory? category) {
    _categoryFilter = category;
    _excludeInteresting = false; // Reset exclude filter when setting a category filter
    notifyListeners();
  }

  void _setCategories() {
    categories = MemoryCategory.values.map((category) {
      final count = memories.where((memory) => memory.category == category).length;
      return Tuple2(category, count);
    }).toList();
    notifyListeners();
  }

  Future<void> init() async {
    await loadMemories();
  }

  Future<void> loadMemories() async {
    _loading = true;
    notifyListeners();

    final response = await getMemories();
    _memories = response.memories;
    _pendingReviewCount = response.pendingReview;

    _unreviewed = _memories
        .where((memory) =>
            !memory.reviewed && memory.createdAt.isAfter(DateTime.now().subtract(const Duration(days: 1))))
        .toList();

    _loading = false;
    _setCategories();
  }

  /// Load memories pending review
  Future<void> loadPendingMemories() async {
    final response = await getMemories(pendingOnly: true);
    _unreviewed = response.memories;
    _pendingReviewCount = response.pendingReview;
    notifyListeners();
  }

  Memory? _lastDeletedMemory;
  Timer? _deletionTimer;
  String? _pendingDeletionId;

  Memory? get lastDeletedMemory => _lastDeletedMemory;

  void deleteMemory(Memory memory) {
    _cancelDeletionTimer();

    _lastDeletedMemory = memory;
    _pendingDeletionId = memory.id;

    _memories.remove(memory);
    _unreviewed.remove(memory);
    _setCategories();
    notifyListeners();

    _startDeletionTimer();
  }

  void _cancelDeletionTimer() {
    if (_deletionTimer != null && _deletionTimer!.isActive) {
      _deletionTimer!.cancel();
      _deletionTimer = null;
    }
  }

  void _startDeletionTimer() {
    _deletionTimer = Timer(const Duration(seconds: 10), () {
      _executeServerDeletion();
    });
  }

  Future<void> _executeServerDeletion() async {
    if (_pendingDeletionId != null) {
      await deleteMemoryServer(_pendingDeletionId!);
      _pendingDeletionId = null;
    }
  }

  // Restore the last deleted memory
  Future<bool> restoreLastDeletedMemory() async {
    if (_lastDeletedMemory == null) return false;

    _cancelDeletionTimer();
    _pendingDeletionId = null;

    _memories.add(_lastDeletedMemory!);
    if (!_lastDeletedMemory!.reviewed &&
        _lastDeletedMemory!.createdAt.isAfter(DateTime.now().subtract(const Duration(days: 1)))) {
      _unreviewed.add(_lastDeletedMemory!);
    }

    _setCategories();
    notifyListeners();

    _lastDeletedMemory = null;

    return true;
  }

  void deleteAllMemories() async {
    final int countBeforeDeletion = _memories.length;
    await deleteAllMemoriesServer();
    _memories.clear();
    _unreviewed.clear();
    if (countBeforeDeletion > 0) {
      MixpanelManager().memoriesAllDeleted(countBeforeDeletion);
    }
    _setCategories();
  }

  Future<Memory?> createMemory(String content,
      [MemoryVisibility visibility = MemoryVisibility.private,
      MemoryCategory category = MemoryCategory.manual]) async {
    final newMemory = await createMemoryServer(
      content: content,
      visibility: visibility.name,
    );

    if (newMemory != null) {
      _memories.add(newMemory);
      _setCategories();
    }

    return newMemory;
  }

  Future<void> updateMemoryVisibility(Memory memory, MemoryVisibility visibility) async {
    await updateMemoryVisibilityServer(memory.id, visibility.name);

    final idx = _memories.indexWhere((m) => m.id == memory.id);
    if (idx != -1) {
      Memory memoryToUpdate = _memories[idx];
      memoryToUpdate.visibility = visibility;
      _memories[idx] = memoryToUpdate;
      _unreviewed.removeWhere((m) => m.id == memory.id);

      MixpanelManager().memoryVisibilityChanged(memoryToUpdate, visibility);
      _setCategories();
    }
  }

  Future<bool> editMemory(Memory memory, String value, [MemoryCategory? category]) async {
    final success = await editMemoryServer(memory.id, value);

    if (success) {
      final idx = _memories.indexWhere((m) => m.id == memory.id);
      if (idx != -1) {
        memory.content = value;
        if (category != null) {
          memory.category = category;
        }
        memory.updatedAt = DateTime.now();
        memory.edited = true;
        _memories[idx] = memory;

        // Remove from unreviewed if it was there
        final unreviewedIdx = _unreviewed.indexWhere((m) => m.id == memory.id);
        if (unreviewedIdx != -1) {
          _unreviewed.removeAt(unreviewedIdx);
        }

        _setCategories();
      }
    }

    return success;
  }

  Future<void> reviewMemory(Memory memory, bool approved, String source) async {
    MixpanelManager().memoryReviewed(memory, approved, source);

    final reviewedMemory = await reviewMemoryServer(memory.id, approved);

    final idx = _memories.indexWhere((m) => m.id == memory.id);
    if (idx != -1) {
      if (!approved) {
        // Memory was rejected - remove it
        _memories.removeAt(idx);
        _unreviewed.remove(memory);
      } else if (reviewedMemory != null) {
        // Memory was approved - update it
        _memories[idx] = reviewedMemory;
        _unreviewed.removeWhere((m) => m.id == memory.id);
      } else {
        // Fallback: update locally
        memory.reviewed = true;
        memory.userReview = approved;
        _memories[idx] = memory;
        _unreviewed.removeWhere((m) => m.id == memory.id);
      }

      _pendingReviewCount = _unreviewed.length;
      _setCategories();
    }
  }

  Future<void> updateAllMemoriesVisibility(bool makePrivate) async {
    final visibility = makePrivate ? MemoryVisibility.private : MemoryVisibility.public;
    int updatedCount = 0;
    List<Memory> memoriesSuccessfullyUpdated = [];

    for (var memory in List.from(_memories)) {
      if (memory.visibility != visibility) {
        try {
          await updateMemoryVisibilityServer(memory.id, visibility.name);
          final idx = _memories.indexWhere((m) => m.id == memory.id);
          if (idx != -1) {
            _memories[idx].visibility = visibility;
            memoriesSuccessfullyUpdated.add(_memories[idx]);
            updatedCount++;
          }
        } catch (e) {
          debugPrint('Failed to update visibility for memory ${memory.id}: $e');
        }
      }
    }

    if (updatedCount > 0) {
      MixpanelManager().memoriesAllVisibilityChanged(visibility, updatedCount);
    }

    _setCategories();
  }

  /// Extract memories from a conversation using AI
  Future<ExtractMemoriesResponse?> extractFromConversation(String conversationId) async {
    final response = await extractMemoriesFromConversation(conversationId);

    if (response != null && response.memoriesCreated > 0) {
      // Add extracted memories to local list
      _memories.addAll(response.memories);
      _unreviewed.addAll(response.memories.where((m) => !m.reviewed));
      _pendingReviewCount += response.memories.where((m) => !m.reviewed).length;
      _setCategories();
    }

    return response;
  }

  /// Search memories semantically
  Future<List<Memory>> semanticSearch(String query, {int limit = 10}) async {
    return await searchMemories(query: query, limit: limit);
  }
}
