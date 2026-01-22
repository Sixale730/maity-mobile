enum MemoryCategory { interesting, system, manual }

enum MemoryVisibility { private, public }

class Memory {
  String id;
  String? userId;
  String? authId;
  String content;
  MemoryCategory category;
  DateTime createdAt;
  DateTime? updatedAt;
  String? conversationId;
  bool reviewed;
  bool? userReview;
  bool manuallyAdded;
  bool edited;
  bool deleted;
  MemoryVisibility visibility;
  bool isLocked;

  Memory({
    required this.id,
    this.userId,
    this.authId,
    required this.content,
    required this.category,
    required this.createdAt,
    this.updatedAt,
    this.conversationId,
    this.reviewed = false,
    this.userReview,
    this.manuallyAdded = false,
    this.edited = false,
    this.deleted = false,
    required this.visibility,
    this.isLocked = false,
  });

  factory Memory.fromJson(Map<String, dynamic> json) {
    return Memory(
      id: json['id'] ?? '',
      userId: json['user_id'],
      authId: json['auth_id'],
      content: json['content'] ?? '',
      category: MemoryCategory.values.firstWhere(
        (e) => e.toString().split('.').last == json['category'],
        orElse: () => MemoryCategory.interesting,
      ),
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at']).toLocal()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at']).toLocal()
          : null,
      conversationId: json['conversation_id'],
      reviewed: json['reviewed'] ?? false,
      userReview: json['user_review'],
      manuallyAdded: json['manually_added'] ?? false,
      edited: json['edited'] ?? false,
      deleted: json['deleted'] ?? false,
      visibility: json['visibility'] != null
          ? (MemoryVisibility.values.asNameMap()[json['visibility']] ?? MemoryVisibility.private)
          : MemoryVisibility.private,
      isLocked: json['is_locked'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'auth_id': authId,
      'content': content,
      'category': category.toString().split('.').last,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt?.toUtc().toIso8601String(),
      'conversation_id': conversationId,
      'reviewed': reviewed,
      'user_review': userReview,
      'manually_added': manuallyAdded,
      'edited': edited,
      'deleted': deleted,
      'visibility': visibility.toString().split('.').last,
      'is_locked': isLocked,
    };
  }
}

class MemoryListResponse {
  List<Memory> memories;
  int total;
  int pendingReview;

  MemoryListResponse({
    required this.memories,
    required this.total,
    required this.pendingReview,
  });

  factory MemoryListResponse.fromJson(Map<String, dynamic> json) {
    return MemoryListResponse(
      memories: (json['memories'] as List?)
              ?.map((m) => Memory.fromJson(m))
              .toList() ??
          [],
      total: json['total'] ?? 0,
      pendingReview: json['pending_review'] ?? 0,
    );
  }
}

class ExtractMemoriesResponse {
  String conversationId;
  int memoriesCreated;
  List<Memory> memories;

  ExtractMemoriesResponse({
    required this.conversationId,
    required this.memoriesCreated,
    required this.memories,
  });

  factory ExtractMemoriesResponse.fromJson(Map<String, dynamic> json) {
    return ExtractMemoriesResponse(
      conversationId: json['conversation_id'] ?? '',
      memoriesCreated: json['memories_created'] ?? 0,
      memories: (json['memories'] as List?)
              ?.map((m) => Memory.fromJson(m))
              .toList() ??
          [],
    );
  }
}
