/// Models for communication feedback analysis

/// Observations about different aspects of communication
class CommunicationObservations {
  final String clarity;
  final String structure;
  final String callsToAction;
  final String objections;

  CommunicationObservations({
    this.clarity = '',
    this.structure = '',
    this.callsToAction = '',
    this.objections = '',
  });

  factory CommunicationObservations.fromJson(Map<String, dynamic> json) {
    return CommunicationObservations(
      clarity: json['clarity'] ?? '',
      structure: json['structure'] ?? '',
      callsToAction: json['calls_to_action'] ?? '',
      objections: json['objections'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'clarity': clarity,
        'structure': structure,
        'calls_to_action': callsToAction,
        'objections': objections,
      };

  bool get hasContent =>
      clarity.isNotEmpty ||
      structure.isNotEmpty ||
      callsToAction.isNotEmpty ||
      objections.isNotEmpty;
}

/// Qualitative feedback about user's communication style
class CommunicationFeedback {
  final List<String> strengths;
  final List<String> areasToImprove;
  final CommunicationObservations observations;
  final String summary;

  CommunicationFeedback({
    this.strengths = const [],
    this.areasToImprove = const [],
    CommunicationObservations? observations,
    this.summary = '',
  }) : observations = observations ?? CommunicationObservations();

  factory CommunicationFeedback.fromJson(Map<String, dynamic> json) {
    return CommunicationFeedback(
      strengths: (json['strengths'] as List<dynamic>?)?.cast<String>() ?? [],
      areasToImprove:
          (json['areas_to_improve'] as List<dynamic>?)?.cast<String>() ?? [],
      observations: json['observations'] != null
          ? CommunicationObservations.fromJson(json['observations'])
          : CommunicationObservations(),
      summary: json['summary'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'strengths': strengths,
        'areas_to_improve': areasToImprove,
        'observations': observations.toJson(),
        'summary': summary,
      };

  bool get hasContent =>
      strengths.isNotEmpty ||
      areasToImprove.isNotEmpty ||
      observations.hasContent;
}

/// Aggregated communication feedback across multiple conversations
class AggregatedFeedback {
  final List<String> topStrengths;
  final List<String> topAreasToImprove;
  final CommunicationObservations observationsSummary;
  final int conversationsAnalyzed;
  final String period;

  AggregatedFeedback({
    this.topStrengths = const [],
    this.topAreasToImprove = const [],
    CommunicationObservations? observationsSummary,
    this.conversationsAnalyzed = 0,
    this.period = '',
  }) : observationsSummary = observationsSummary ?? CommunicationObservations();

  factory AggregatedFeedback.fromJson(Map<String, dynamic> json) {
    return AggregatedFeedback(
      topStrengths:
          (json['top_strengths'] as List<dynamic>?)?.cast<String>() ?? [],
      topAreasToImprove:
          (json['top_areas_to_improve'] as List<dynamic>?)?.cast<String>() ??
              [],
      observationsSummary: json['observations_summary'] != null
          ? CommunicationObservations.fromJson(json['observations_summary'])
          : CommunicationObservations(),
      conversationsAnalyzed: json['conversations_analyzed'] ?? 0,
      period: json['period'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'top_strengths': topStrengths,
        'top_areas_to_improve': topAreasToImprove,
        'observations_summary': observationsSummary.toJson(),
        'conversations_analyzed': conversationsAnalyzed,
        'period': period,
      };

  bool get hasContent =>
      topStrengths.isNotEmpty ||
      topAreasToImprove.isNotEmpty ||
      conversationsAnalyzed > 0;
}

/// Response from communication feedback API
class CommunicationFeedbackResponse {
  final String userId;
  final String period;
  final AggregatedFeedback feedback;

  CommunicationFeedbackResponse({
    required this.userId,
    required this.period,
    required this.feedback,
  });

  factory CommunicationFeedbackResponse.fromJson(Map<String, dynamic> json) {
    return CommunicationFeedbackResponse(
      userId: json['user_id'] ?? '',
      period: json['period'] ?? '',
      feedback: AggregatedFeedback.fromJson(json['feedback'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'period': period,
        'feedback': feedback.toJson(),
      };
}
