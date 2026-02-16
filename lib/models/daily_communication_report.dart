class DailyScores {
  // 6-competency standard scores
  final double clarity;
  final double structure;
  final double vocabulario;
  final double empatia;
  final double objetivo;
  final double adaptacion;
  final double overall;
  // Legacy fields (kept for backward compat)
  final double callsToAction;
  final double objectionHandling;

  const DailyScores({
    this.clarity = 0,
    this.structure = 0,
    this.vocabulario = 0,
    this.empatia = 0,
    this.objetivo = 0,
    this.adaptacion = 0,
    this.overall = 0,
    this.callsToAction = 0,
    this.objectionHandling = 0,
  });

  factory DailyScores.fromJson(Map<String, dynamic> json) {
    return DailyScores(
      clarity: (json['clarity'] as num?)?.toDouble() ?? 0,
      structure: (json['structure'] as num?)?.toDouble() ?? 0,
      vocabulario: (json['vocabulario'] as num?)?.toDouble() ?? 0,
      empatia: (json['empatia'] as num?)?.toDouble() ?? 0,
      objetivo: (json['objetivo'] as num?)?.toDouble() ?? 0,
      adaptacion: (json['adaptacion'] as num?)?.toDouble() ?? 0,
      overall: (json['overall'] as num?)?.toDouble() ?? 0,
      callsToAction: (json['calls_to_action'] as num?)?.toDouble() ?? 0,
      objectionHandling: (json['objection_handling'] as num?)?.toDouble() ?? 0,
    );
  }

  /// True if this report has the new 6-competency scores
  bool get hasNewScores => vocabulario > 0 || empatia > 0 || objetivo > 0 || adaptacion > 0;
}

class DailyTrend {
  final String trend; // improving, stable, declining, first_report
  final double? previousOverall;
  final double? change;

  const DailyTrend({
    this.trend = 'first_report',
    this.previousOverall,
    this.change,
  });

  factory DailyTrend.fromJson(Map<String, dynamic> json) {
    return DailyTrend(
      trend: json['trend'] as String? ?? 'first_report',
      previousOverall: (json['previous_overall'] as num?)?.toDouble(),
      change: (json['change'] as num?)?.toDouble(),
    );
  }

  bool get isImproving => trend == 'improving';
  bool get isStable => trend == 'stable';
  bool get isDeclining => trend == 'declining';
  bool get isFirstReport => trend == 'first_report';
}

class DailyCommunicationReport {
  final String id;
  final String userId;
  final String reportDate;
  final int conversationsAnalyzed;
  final int totalWordsAnalyzed;
  final int totalDurationSeconds;
  final Map<String, int> totalFillerWords;
  final int totalFillerCount;
  final int totalPeroCount;
  final Map<String, int> totalObjectionWords;
  final List<String> objectionsReceived;
  final List<String> objectionsMade;
  final DailyScores scores;
  final List<String> topStrengths;
  final List<String> topAreasToImprove;
  final String dailySummary;
  final List<String> recommendations;
  final DailyTrend trend;
  final List<String> conversationIds;
  final String? createdAt;

  const DailyCommunicationReport({
    required this.id,
    required this.userId,
    required this.reportDate,
    this.conversationsAnalyzed = 0,
    this.totalWordsAnalyzed = 0,
    this.totalDurationSeconds = 0,
    this.totalFillerWords = const {},
    this.totalFillerCount = 0,
    this.totalPeroCount = 0,
    this.totalObjectionWords = const {},
    this.objectionsReceived = const [],
    this.objectionsMade = const [],
    this.scores = const DailyScores(),
    this.topStrengths = const [],
    this.topAreasToImprove = const [],
    this.dailySummary = '',
    this.recommendations = const [],
    this.trend = const DailyTrend(),
    this.conversationIds = const [],
    this.createdAt,
  });

  factory DailyCommunicationReport.fromJson(Map<String, dynamic> json) {
    return DailyCommunicationReport(
      id: json['id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      reportDate: json['report_date'] as String? ?? '',
      conversationsAnalyzed: json['conversations_analyzed'] as int? ?? 0,
      totalWordsAnalyzed: json['total_words_analyzed'] as int? ?? 0,
      totalDurationSeconds: json['total_duration_seconds'] as int? ?? 0,
      totalFillerWords: _parseIntMap(json['total_filler_words']),
      totalFillerCount: json['total_filler_count'] as int? ?? 0,
      totalPeroCount: json['total_pero_count'] as int? ?? 0,
      totalObjectionWords: _parseIntMap(json['total_objection_words']),
      objectionsReceived: _parseStringList(json['objections_received']),
      objectionsMade: _parseStringList(json['objections_made']),
      scores: json['scores'] != null
          ? DailyScores.fromJson(json['scores'] as Map<String, dynamic>)
          : const DailyScores(),
      topStrengths: _parseStringList(json['top_strengths']),
      topAreasToImprove: _parseStringList(json['top_areas_to_improve']),
      dailySummary: json['daily_summary'] as String? ?? '',
      recommendations: _parseStringList(json['recommendations']),
      trend: json['trend'] != null
          ? DailyTrend.fromJson(json['trend'] as Map<String, dynamic>)
          : const DailyTrend(),
      conversationIds: _parseStringList(json['conversation_ids']),
      createdAt: json['created_at'] as String?,
    );
  }

  bool get isToday {
    final now = DateTime.now();
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return reportDate == todayStr;
  }

  int get totalDurationMinutes => (totalDurationSeconds / 60).round();

  static Map<String, int> _parseIntMap(dynamic value) {
    if (value == null) return {};
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), (v is int) ? v : (v as num?)?.toInt() ?? 0));
    }
    return {};
  }

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return [];
  }
}
