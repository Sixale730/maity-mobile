import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/services/local_conversations_service.dart';
import 'package:omi/services/maity_api_service.dart';
import 'package:omi/services/omi_supabase_service.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/services/app_review_service.dart';

class ConversationProvider extends ChangeNotifier {
  List<ServerConversation> conversations = [];
  List<ServerConversation> searchedConversations = [];
  Map<DateTime, List<ServerConversation>> groupedConversations = {};

  bool isLoadingConversations = false;
  bool showDiscardedConversations = false;
  bool showShortConversations = SharedPreferencesUtil().showShortConversations;
  int shortConversationThreshold = SharedPreferencesUtil().shortConversationThreshold;
  DateTime? selectedDate;

  // Category filter state
  String? selectedCategory; // null = All categories
  bool showStarredOnly = false;

  String previousQuery = '';
  int totalSearchPages = 1;
  int currentSearchPage = 1;

  // Semantic search state
  List<SemanticSearchResult> semanticSearchResults = [];
  bool isSemanticSearching = false;
  bool useSemanticSearch = true; // Toggle for semantic vs text search

  Timer? _processingConversationWatchTimer;

  // Add debounce mechanism for refresh
  Timer? _refreshDebounceTimer;
  DateTime? _lastRefreshTime;
  static const Duration _refreshCooldown = Duration(seconds: 60); // Minimum time between refreshes

  List<ServerConversation> processingConversations = [];

  final AppReviewService _appReviewService = AppReviewService();

  bool isFetchingConversations = false;

  ConversationProvider() {
    _preload();
  }

  _preload() async {
    // Initialization logic if needed
  }

  void resetGroupedConvos() {
    groupConversationsByDate();
  }

  Future updateSearchedConvoDetails(String id, DateTime date, int idx) async {
    var convo = await getConversationById(id);
    if (convo != null) {
      updateSpecificGroupedConvo(convo, date, idx);
    }
    notifyListeners();
  }

  void updateSpecificGroupedConvo(ServerConversation convo, DateTime date, int idx) {
    groupedConversations[date]![idx] = convo;
    notifyListeners();
  }

  Future<void> searchConversations(String query, {bool showShimmer = false}) async {
    if (query.isEmpty) {
      previousQuery = "";
      currentSearchPage = 0;
      totalSearchPages = 0;
      searchedConversations = [];
      groupConversationsByDate();
      return;
    }

    if (showShimmer) {
      setLoadingConversations(true);
    } else {
      setIsFetchingConversations(true);
    }

    previousQuery = query;

    // Use local search instead of disabled api.omi.me
    final convos = LocalConversationsService.searchConversations(query);
    convos.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    searchedConversations = convos;
    currentSearchPage = 1;
    totalSearchPages = 1; // Local search returns all results at once
    groupSearchConvosByDate();

    if (showShimmer) {
      setLoadingConversations(false);
    } else {
      setIsFetchingConversations(false);
    }

    notifyListeners();
  }

  Future<void> searchMoreConversations() async {
    // Local search returns all results at once, no pagination needed
    if (totalSearchPages <= currentSearchPage) {
      return;
    }
    // No-op for local search since all results are returned in the first call
  }

  /// Toggle between semantic search and text-based search
  void toggleSemanticSearch() {
    useSemanticSearch = !useSemanticSearch;
    notifyListeners();
  }

  /// Clear all search states (both text and semantic)
  void clearSearch() {
    previousQuery = "";
    searchedConversations = [];
    semanticSearchResults = [];
    groupConversationsByDate();
    notifyListeners();
  }

  /// Perform semantic search using vector similarity in Supabase
  /// Falls back to text-based search if semantic search fails
  /// [userId] es el UUID de maity.users (no el firebase_uid)
  Future<void> semanticSearchConversations(String query, {String? userId}) async {
    if (query.isEmpty) {
      semanticSearchResults = [];
      previousQuery = "";
      groupConversationsByDate();
      return;
    }

    if (userId == null || userId.isEmpty) {
      debugPrint('[ConversationProvider] No user ID for semantic search, falling back to text search');
      await searchConversations(query);
      return;
    }

    isSemanticSearching = true;
    previousQuery = query;
    notifyListeners();

    try {
      final results = await OmiSupabaseService.searchConversations(
        userId: userId,
        query: query,
        limit: 20,
        similarityThreshold: 0.3,
        includeDiscarded: showDiscardedConversations,
      );

      semanticSearchResults = results;
      debugPrint('[ConversationProvider] Semantic search found ${results.length} results');

      // If no semantic results, fall back to text search
      if (results.isEmpty) {
        debugPrint('[ConversationProvider] No semantic results, falling back to text search');
        await searchConversations(query);
      }
    } catch (e) {
      debugPrint('[ConversationProvider] Semantic search error: $e, falling back to text search');
      await searchConversations(query);
    } finally {
      isSemanticSearching = false;
      notifyListeners();
    }
  }

  /// Search for specific transcript segments using vector similarity
  /// [userId] es el UUID de maity.users
  Future<List<SegmentSearchResult>> searchTranscriptSegments(String query, {String? userId}) async {
    if (query.isEmpty || userId == null) return [];

    try {
      return await OmiSupabaseService.searchSegments(
        userId: userId,
        query: query,
        limit: 30,
        similarityThreshold: 0.3,
      );
    } catch (e) {
      debugPrint('[ConversationProvider] Segment search error: $e');
      return [];
    }
  }

  /// Get conversations from Supabase (vector DB)
  /// [userId] es el UUID de maity.users
  Future<List<OmiConversation>> getSupabaseConversations({
    required String userId,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      return await OmiSupabaseService.getConversations(
        userId: userId,
        limit: limit,
        offset: offset,
        includeDiscarded: showDiscardedConversations,
      );
    } catch (e) {
      debugPrint('[ConversationProvider] Get Supabase conversations error: $e');
      return [];
    }
  }

  int groupedSearchConvoIndex(ServerConversation convo) {
    var convoDate = convo.startedAt ?? convo.createdAt;
    var date = DateTime(convoDate.year, convoDate.month, convoDate.day);
    if (groupedConversations.containsKey(date)) {
      return groupedConversations[date]!.indexWhere((element) => element.id == convo.id);
    }
    return -1;
  }

  void addProcessingConversation(ServerConversation conversation) {
    processingConversations.add(conversation);
    notifyListeners();
  }

  void removeProcessingConversation(String conversationId) {
    processingConversations.removeWhere((m) => m.id == conversationId);
    notifyListeners();
  }

  void onConversationTap(int idx) {
    if (idx < 0 || idx > conversations.length - 1) {
      return;
    }
    var changed = false;
    if (conversations[idx].isNew) {
      conversations[idx].isNew = false;
      changed = true;
    }
    if (changed) {
      groupConversationsByDate();
    }
  }

  void toggleDiscardConversations() {
    showDiscardedConversations = !showDiscardedConversations;

    // Clear grouped conversations to show shimmer effect while loading
    groupedConversations = {};
    notifyListeners();

    if (previousQuery.isNotEmpty) {
      searchConversations(previousQuery, showShimmer: true);
    } else {
      fetchConversations();
    }

    MixpanelManager().showDiscardedMemoriesToggled(showDiscardedConversations);
  }

  void toggleShortConversations() {
    showShortConversations = !showShortConversations;
    SharedPreferencesUtil().showShortConversations = showShortConversations;
    groupConversationsByDate();
  }

  void setShortConversationThreshold(int seconds) {
    shortConversationThreshold = seconds;
    SharedPreferencesUtil().shortConversationThreshold = seconds;
    // If threshold is 0, show all conversations; otherwise filter by threshold
    showShortConversations = seconds == 0;
    SharedPreferencesUtil().showShortConversations = showShortConversations;
    groupConversationsByDate();
  }

  void setLoadingConversations(bool value) {
    isLoadingConversations = value;
    notifyListeners();
  }

  Future refreshConversations() async {
    // Debounce mechanism: only refresh if enough time has passed since last refresh
    final now = DateTime.now();
    if (_lastRefreshTime != null && now.difference(_lastRefreshTime!) < _refreshCooldown) {
      debugPrint(
          'Skipping conversations refresh - too soon since last refresh (${now.difference(_lastRefreshTime!).inSeconds}s ago)');
      return;
    }

    // Cancel any pending refresh
    _refreshDebounceTimer?.cancel();

    // Set debounce timer
    _refreshDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _lastRefreshTime = DateTime.now();
      _fetchNewConversations();
    });
  }

  // Force refresh bypassing debounce (for manual refresh, connection restored, etc.)
  Future forceRefreshConversations() async {
    _refreshDebounceTimer?.cancel();
    _lastRefreshTime = DateTime.now();
    await _fetchNewConversations();
  }

  Future _fetchNewConversations() async {
    setLoadingConversations(true);
    List<ServerConversation> newConversations = await _getConversationsFromServer();
    setLoadingConversations(false);

    List<ServerConversation> upsertConvos = [];

    // processing convos
    upsertConvos = newConversations
        .where((c) =>
            c.status == ConversationStatus.processing &&
            processingConversations.indexWhere((cc) => cc.id == c.id) == -1)
        .toList();
    if (upsertConvos.isNotEmpty) {
      processingConversations.insertAll(0, upsertConvos);
    }

    // completed convos
    upsertConvos = newConversations
        .where((c) => c.status == ConversationStatus.completed && conversations.indexWhere((cc) => cc.id == c.id) == -1)
        .toList();
    if (upsertConvos.isNotEmpty) {
      // Check if this is the first conversation
      bool wasEmpty = conversations.isEmpty;

      conversations.insertAll(0, upsertConvos);

      // Mark first conversation for app review
      if (wasEmpty && await _appReviewService.isFirstConversation()) {
        await _appReviewService.markFirstConversation();
      }
    }

    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  Future fetchConversations() async {
    previousQuery = "";
    currentSearchPage = 0;
    totalSearchPages = 0;
    searchedConversations = [];

    setLoadingConversations(true);
    conversations = await _getConversationsFromServer();
    setLoadingConversations(false);

    // processing convos
    processingConversations = conversations.where((m) => m.status == ConversationStatus.processing).toList();

    // completed convos
    conversations = conversations.where((m) => m.status == ConversationStatus.completed).toList();
    if (conversations.isEmpty) {
      conversations = SharedPreferencesUtil().cachedConversations;
    } else {
      SharedPreferencesUtil().cachedConversations = conversations;
    }

    // Load and merge local conversations (from custom STT/Direct Deepgram mode)
    loadLocalConversations();

    if (searchedConversations.isEmpty) {
      searchedConversations = conversations;
    }
    _groupConversationsByDateWithoutNotify();

    notifyListeners();
  }

  Future getInitialConversations() async {
    await fetchConversations();
  }

  List<ServerConversation> _filterOutConvos(List<ServerConversation> convos) {
    return convos.where((convo) {
      // Filter by discarded status
      if (showDiscardedConversations) {
        // When showing discarded conversations, only show discarded ones
        if (!convo.discarded) {
          return false;
        }
      } else {
        // When not showing discarded conversations, only show non-discarded ones
        if (convo.discarded) {
          return false;
        }
      }

      // Filter out short conversations unless explicitly showing them
      if (!showShortConversations && shortConversationThreshold > 0) {
        final durationSeconds = convo.getDurationInSeconds();
        if (durationSeconds < shortConversationThreshold) {
          return false;
        }
      }

      // Apply date filter if selected
      if (selectedDate != null) {
        var effectiveDate = convo.startedAt ?? convo.createdAt;
        var convoDate = DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
        var filterDate = DateTime(selectedDate!.year, selectedDate!.month, selectedDate!.day);
        if (convoDate != filterDate) {
          return false;
        }
      }

      // Apply starred filter
      if (showStarredOnly && !convo.starred) {
        return false;
      }

      // Apply category filter
      if (selectedCategory != null) {
        final convoCategory = convo.structured.category.toLowerCase();
        if (convoCategory != selectedCategory!.toLowerCase()) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  /// Filter conversations by a specific date
  Future<void> filterConversationsByDate(DateTime date) async {
    selectedDate = date;

    // Clear search when applying date filter
    previousQuery = "";
    currentSearchPage = 0;
    totalSearchPages = 0;
    searchedConversations = [];

    // Re-apply grouping with date filter
    groupConversationsByDate();
    notifyListeners();
  }

  /// Clear the date filter
  Future<void> clearDateFilter() async {
    selectedDate = null;

    // Clear search when clearing date filter
    previousQuery = "";
    currentSearchPage = 0;
    totalSearchPages = 0;
    searchedConversations = [];

    // Re-apply grouping without date filter
    groupConversationsByDate();
    notifyListeners();
  }

  /// Set category filter
  void setCategoryFilter(String? category) {
    selectedCategory = category;
    // Clear starred filter when selecting a category
    if (category != null) {
      showStarredOnly = false;
    }
    groupConversationsByDate();
    notifyListeners();
  }

  /// Toggle starred filter
  void toggleStarredFilter() {
    showStarredOnly = !showStarredOnly;
    // Clear category filter when toggling starred
    if (showStarredOnly) {
      selectedCategory = null;
    }
    groupConversationsByDate();
    notifyListeners();
  }

  /// Clear all filters (category, starred, date)
  void clearAllFilters() {
    selectedCategory = null;
    showStarredOnly = false;
    selectedDate = null;
    groupConversationsByDate();
    notifyListeners();
  }

  void _groupSearchConvosByDateWithoutNotify() {
    groupedConversations = {};
    for (var conversation in _filterOutConvos(searchedConversations)) {
      var effectiveDate = conversation.startedAt ?? conversation.createdAt;
      var date = DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
      if (!groupedConversations.containsKey(date)) {
        groupedConversations[date] = [];
      }
      groupedConversations[date]?.add(conversation);
    }

    // Sort
    for (final date in groupedConversations.keys) {
      groupedConversations[date]?.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    }
  }

  void _groupConversationsByDateWithoutNotify() {
    groupedConversations = {};
    for (var conversation in _filterOutConvos(conversations)) {
      var effectiveDate = conversation.startedAt ?? conversation.createdAt;
      var date = DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
      if (!groupedConversations.containsKey(date)) {
        groupedConversations[date] = [];
      }
      groupedConversations[date]?.add(conversation);
    }

    // Sort
    for (final date in groupedConversations.keys) {
      groupedConversations[date]?.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    }
  }

  void groupConversationsByDate() {
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  void groupSearchConvosByDate() {
    _groupSearchConvosByDateWithoutNotify();
    notifyListeners();
  }

  Future<List<ServerConversation>> _getConversationsFromServer() async {
    // Try to get from Supabase first (our own database)
    // Wait for maityUserId to be available (max 5 seconds) - handles race condition after app reinstall
    String? userId = SupabaseAuthService.instance.maityUserId;

    if (userId == null) {
      debugPrint('[ConversationProvider] maityUserId is null, waiting for auth to initialize...');
      // Aumentar a 10 intentos (5 segundos) para dar tiempo a _fetchMaityUserId()
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        userId = SupabaseAuthService.instance.maityUserId;
        if (userId != null) {
          debugPrint('[ConversationProvider] maityUserId available after ${(i + 1) * 500}ms: $userId');
          break;
        }
      }

      if (userId == null) {
        debugPrint('[ConversationProvider] maityUserId still null after 5s, using fallback');
      }
    } else {
      debugPrint('[ConversationProvider] maityUserId already available: $userId');
    }

    if (userId != null) {
      try {
        debugPrint('[ConversationProvider] Fetching conversations from Supabase for user: $userId');
        final supabaseConvos = await OmiSupabaseService.getConversations(
          userId: userId,
          limit: 50,
          includeDiscarded: showDiscardedConversations,
        );
        debugPrint('[ConversationProvider] Received ${supabaseConvos.length} conversations from Supabase');
        if (supabaseConvos.isNotEmpty) {
          debugPrint('[ConversationProvider] Loaded ${supabaseConvos.length} conversations from Supabase');
          // Convert OmiConversation to ServerConversation
          return supabaseConvos.map((c) => c.toServerConversation()).toList();
        }
      } catch (e) {
        debugPrint('[ConversationProvider] Error loading from Supabase: $e');
      }
    }

    // Fallback to api.omi.me (will likely fail with 401)
    debugPrint('[ConversationProvider] Falling back to api.omi.me');
    return await getConversations(includeDiscarded: showDiscardedConversations);
  }

  void updateActionItemState(String convoId, bool state, int i, DateTime date) {
    conversations.firstWhere((element) => element.id == convoId).structured.actionItems[i].completed = state;
    groupedConversations[date]!.firstWhere((element) => element.id == convoId).structured.actionItems[i].completed =
        state;
    notifyListeners();
  }

  Future getMoreConversationsFromServer() async {
    if (conversations.length % 50 != 0) return;
    if (isLoadingConversations) return;
    setLoadingConversations(true);
    var newConversations =
        await getConversations(offset: conversations.length, includeDiscarded: showDiscardedConversations);
    conversations.addAll(newConversations);
    conversations.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    _groupConversationsByDateWithoutNotify();
    setLoadingConversations(false);
    notifyListeners();
  }

  Future<void> addConversation(ServerConversation conversation) async {
    // Check if this is the first conversation
    bool wasEmpty = conversations.isEmpty;

    conversations.insert(0, conversation);
    _groupConversationsByDateWithoutNotify();

    // Mark first conversation for app review
    if (wasEmpty && await _appReviewService.isFirstConversation()) {
      await _appReviewService.markFirstConversation();
    }

    notifyListeners();
  }

  /// Adds a locally saved conversation (from custom STT/Direct Deepgram mode)
  void addLocalConversation(ServerConversation conversation) {
    // Check if already exists
    if (conversations.any((c) => c.id == conversation.id)) {
      debugPrint('[ConversationProvider] Local conversation ${conversation.id} already exists, skipping');
      return;
    }

    debugPrint('[ConversationProvider] Adding local conversation: ${conversation.id}');
    conversations.insert(0, conversation);
    conversations.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  /// Loads local conversations from storage and merges with server conversations
  void loadLocalConversations() {
    final localConvs = LocalConversationsService.getLocalConversations();
    debugPrint('[ConversationProvider] Loading ${localConvs.length} local conversations');

    int addedCount = 0;
    for (final conv in localConvs) {
      if (!conversations.any((c) => c.id == conv.id)) {
        conversations.add(conv);
        addedCount++;
      }
    }

    if (addedCount > 0) {
      debugPrint('[ConversationProvider] Added $addedCount new local conversations');
      conversations.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
      _groupConversationsByDateWithoutNotify();
      notifyListeners();
    }
  }

  void upsertConversation(ServerConversation conversation) {
    int idx = conversations.indexWhere((m) => m.id == conversation.id);
    if (idx < 0) {
      addConversation(conversation);
    } else {
      updateConversation(conversation, idx);
    }
  }

  void updateConversationInSortedList(ServerConversation conversation) {
    var effectiveDate = conversation.startedAt ?? conversation.createdAt;
    var date = DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
    if (groupedConversations.containsKey(date)) {
      int idx = groupedConversations[date]!.indexWhere((element) => element.id == conversation.id);
      if (idx != -1) {
        groupedConversations[date]![idx] = conversation;
      }
    }
    notifyListeners();
  }

  (int, DateTime) addConversationWithDateGrouped(ServerConversation conversation) {
    conversations.insert(0, conversation);
    conversations.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    int idx;
    var effectiveDate = conversation.startedAt ?? conversation.createdAt;
    var memDate = DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
    if (groupedConversations.containsKey(memDate)) {
      var convoEffectiveDate = conversation.startedAt ?? conversation.createdAt;
      idx = groupedConversations[memDate]!
          .indexWhere((element) => (element.startedAt ?? element.createdAt).isBefore(convoEffectiveDate));
      if (idx == -1) {
        groupedConversations[memDate]!.insert(0, conversation);
        idx = 0;
      } else {
        groupedConversations[memDate]!.insert(idx, conversation);
      }
    } else {
      groupedConversations[memDate] = [conversation];
      groupedConversations =
          Map.fromEntries(groupedConversations.entries.toList()..sort((a, b) => b.key.compareTo(a.key)));
      idx = 0;
    }
    return (idx, memDate);
  }

  void updateConversation(ServerConversation conversation, [int? index]) {
    if (index != null) {
      conversations[index] = conversation;
    } else {
      int i = conversations.indexWhere((element) => element.id == conversation.id);
      if (i != -1) {
        conversations[i] = conversation;
      }
    }
    conversations.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  /// Toggle the starred (favorite) status of a conversation
  Future<void> toggleConversationStarred(ServerConversation conversation) async {
    final newState = !conversation.starred;
    final userId = SupabaseAuthService.instance.maityUserId;

    if (userId == null || userId.isEmpty) {
      debugPrint('[ConversationProvider] No user ID for starring conversation');
      return;
    }

    // Optimistically update UI
    conversation.starred = newState;
    updateConversationInSortedList(conversation);

    // Update on server
    final success = await MaityApiService.setConversationStarred(
      conversation.id,
      userId,  // Now guaranteed non-null after the check above
      newState,
    );

    if (!success) {
      // Revert on failure
      conversation.starred = !newState;
      updateConversationInSortedList(conversation);
      debugPrint('[ConversationProvider] Failed to update starred status');
    }
  }

  // _handleCalendarCreation(ServerMemory memory) {
  //   if (!SharedPreferencesUtil().calendarEnabled) return;
  //   if (SharedPreferencesUtil().calendarType != 'auto') return;
  //
  //   List<Event> events = memory.structured.events;
  //   if (events.isEmpty) return;
  //
  //   List<int> indexes = events.mapIndexed((index, e) => index).toList();
  //   setMemoryEventsState(memory.id, indexes, indexes.map((_) => true).toList());
  //   for (var i = 0; i < events.length; i++) {
  //     if (events[i].created) continue;
  //     events[i].created = true;
  //     CalendarUtil().createEvent(
  //       events[i].title,
  //       events[i].startsAt,
  //       events[i].duration,
  //       description: events[i].description,
  //     );
  //   }
  // }

  /////////////////////////////////////////////////////////////////
  ////////// Delete Memory With Undo Functionality ///////////////

  Map<String, ServerConversation> memoriesToDelete = {};
  String? lastDeletedConversationId;
  Map<String, DateTime> deleteTimestamps = {};

  void deleteConversationLocally(ServerConversation conversation, int index, DateTime date) {
    if (lastDeletedConversationId != null &&
        memoriesToDelete.containsKey(lastDeletedConversationId) &&
        DateTime.now().difference(deleteTimestamps[lastDeletedConversationId]!) < const Duration(seconds: 3)) {
      deleteConversationOnServer(lastDeletedConversationId!);
    }

    memoriesToDelete[conversation.id] = conversation;
    lastDeletedConversationId = conversation.id;
    deleteTimestamps[conversation.id] = DateTime.now();
    conversations.removeWhere((element) => element.id == conversation.id);
    groupedConversations[date]!.removeAt(index);
    if (groupedConversations[date]!.isEmpty) {
      groupedConversations.remove(date);
    }
    notifyListeners();
    Future.delayed(const Duration(seconds: 3), () {
      if (memoriesToDelete.containsKey(conversation.id) && lastDeletedConversationId == conversation.id) {
        deleteConversationOnServer(conversation.id);
      }
    });
  }

  void deleteConversationOnServer(String conversationId) async {
    // Delete from Supabase via OmiSupabaseService
    final userId = SupabaseAuthService.instance.maityUserId;
    if (userId != null) {
      final success = await OmiSupabaseService.deleteConversation(
        conversationId: conversationId,
        userId: userId,
      );
      debugPrint('[ConversationProvider] Delete from Supabase: $success');
    }

    // Also delete from local storage
    await LocalConversationsService.deleteConversation(conversationId);

    memoriesToDelete.remove(conversationId);
    deleteTimestamps.remove(conversationId);
    if (lastDeletedConversationId == conversationId) {
      lastDeletedConversationId = null;
    }
  }

  void undoDeletedConversation(ServerConversation conversation) {
    if (!conversations.any((e) => e.id == conversation.id)) {
      conversations.add(conversation);
      conversations.sort((a, b) => (b.startedAt ?? b.createdAt).compareTo(a.startedAt ?? a.createdAt));
      _groupConversationsByDateWithoutNotify();
    }
    memoriesToDelete.remove(conversation.id);
    deleteTimestamps.remove(conversation.id);
    if (lastDeletedConversationId == conversation.id) {
      lastDeletedConversationId = null;
    }
    notifyListeners();
  }

  /////////////////////////////////////////////////////////////////

  void deleteConversation(ServerConversation conversation, int index) {
    conversations.removeWhere((element) => element.id == conversation.id);
    deleteConversationServer(conversation.id);
    _groupConversationsByDateWithoutNotify();
    notifyListeners();
  }

  @override
  void dispose() {
    _processingConversationWatchTimer?.cancel();
    _refreshDebounceTimer?.cancel();
    super.dispose();
  }

  void setIsFetchingConversations(bool value) {
    isFetchingConversations = value;
    notifyListeners();
  }

  // New Getter for Action Items Page
  Map<ServerConversation, List<ActionItem>> get conversationsWithActiveActionItems {
    final Map<ServerConversation, List<ActionItem>> result = {};
    final List<ServerConversation> sourceList = conversations;

    for (final convo in sourceList) {
      if (convo.discarded && !showDiscardedConversations) continue;

      final activeItems = convo.structured.actionItems.where((item) => !item.deleted).toList();
      if (activeItems.isNotEmpty) {
        result[convo] = activeItems;
      }
    }
    return result;
  }

  Future<void> updateGlobalActionItemState(
      ServerConversation conversation, String actionItemDescription, bool newState) async {
    final convoId = conversation.id;
    bool conversationFoundAndUpdated = false;

    final originalConvoIndex = conversations.indexWhere((c) => c.id == convoId);
    if (originalConvoIndex != -1) {
      final itemIndex = conversations[originalConvoIndex]
          .structured
          .actionItems
          .indexWhere((item) => item.description == actionItemDescription);
      if (itemIndex != -1) {
        conversations[originalConvoIndex].structured.actionItems[itemIndex].completed = newState;
        conversationFoundAndUpdated = true;
      }
    }

    var effectiveDate = conversation.startedAt ?? conversation.createdAt;
    var dateKey = DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
    if (groupedConversations.containsKey(dateKey)) {
      final groupIndex = groupedConversations[dateKey]!.indexWhere((c) => c.id == convoId);
      if (groupIndex != -1) {
        final itemIndex = groupedConversations[dateKey]![groupIndex]
            .structured
            .actionItems
            .indexWhere((item) => item.description == actionItemDescription);
        if (itemIndex != -1) {
          groupedConversations[dateKey]![groupIndex].structured.actionItems[itemIndex].completed = newState;
        }
      }
    }

    if (conversationFoundAndUpdated) {
      // Find the item index for the server call
      final itemIndex =
          conversation.structured.actionItems.indexWhere((item) => item.description == actionItemDescription);
      if (itemIndex != -1) {
        await setConversationActionItemState(convoId, [itemIndex], [newState]);
      }
      notifyListeners();
    } else {
      debugPrint("Error: Conversation or action item not found for updateGlobalActionItemState.");
    }
  }

  void updateActionItemDescriptionInConversation(String conversationId, int itemIndex, String newDescription) {
    final convoIndex = conversations.indexWhere((c) => c.id == conversationId);
    if (convoIndex != -1) {
      if (conversations[convoIndex].structured.actionItems.length > itemIndex) {
        conversations[convoIndex].structured.actionItems[itemIndex].description = newDescription;
      }
    }

    groupedConversations.forEach((date, convoList) {
      final groupIndex = convoList.indexWhere((c) => c.id == conversationId);
      if (groupIndex != -1) {
        if (convoList[groupIndex].structured.actionItems.length > itemIndex) {
          convoList[groupIndex].structured.actionItems[itemIndex].description = newDescription;
        }
      }
    });

    notifyListeners();
  }

  Future<void> deleteActionItemAndUpdateLocally(String conversationId, int itemIndex, ActionItem actionItem) async {
    deleteConversationActionItem(conversationId, actionItem);

    final convoIndex = conversations.indexWhere((c) => c.id == conversationId);
    if (convoIndex != -1) {
      if (conversations[convoIndex].structured.actionItems.length > itemIndex) {
        conversations[convoIndex].structured.actionItems.removeAt(itemIndex);
      }
    }

    groupedConversations.forEach((date, convoList) {
      final groupConvoIndex = convoList.indexWhere((c) => c.id == conversationId);
      if (groupConvoIndex != -1) {
        if (convoList[groupConvoIndex].structured.actionItems.length > itemIndex) {
          convoList[groupConvoIndex].structured.actionItems.removeAt(itemIndex);
        }
      }
    });

    notifyListeners();
  }

  (DateTime, int) getConversationDateAndIndex(ServerConversation conversation) {
    var effectiveDate = conversation.startedAt ?? conversation.createdAt;
    var date = DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
    var idx = groupedConversations[date]!.indexWhere((element) => element.id == conversation.id);
    if (idx == -1 && groupedConversations.containsKey(date)) {
      groupedConversations[date]!.add(conversation);
    }
    return (date, idx);
  }

  void updateSyncedConversation(ServerConversation conversation) {
    updateConversationInSortedList(conversation);
    notifyListeners();
  }
}
