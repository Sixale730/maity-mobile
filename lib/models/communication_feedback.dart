/// Models for communication feedback analysis - 6 competency standard
library;

import 'package:flutter/material.dart';

/// Observations about different aspects of communication (legacy)
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

/// Quantitative metrics about communication patterns
class CommunicationCounters {
  final int peroCount;
  final Map<String, int> objectionWords;
  final List<String> objectionsReceived;
  final List<String> objectionsMade;
  final Map<String, int> fillerWords;

  CommunicationCounters({
    this.peroCount = 0,
    this.objectionWords = const {},
    this.objectionsReceived = const [],
    this.objectionsMade = const [],
    this.fillerWords = const {},
  });

  factory CommunicationCounters.fromJson(Map<String, dynamic> json) {
    return CommunicationCounters(
      peroCount: json['pero_count'] ?? 0,
      objectionWords: (json['objection_words'] as Map<String, dynamic>?)
              ?.map((key, value) => MapEntry(key, value as int)) ??
          {},
      objectionsReceived:
          (json['objections_received'] as List<dynamic>?)?.cast<String>() ?? [],
      objectionsMade:
          (json['objections_made'] as List<dynamic>?)?.cast<String>() ?? [],
      fillerWords: (json['filler_words'] as Map<String, dynamic>?)
              ?.map((key, value) => MapEntry(key, value as int)) ??
          {},
    );
  }

  Map<String, dynamic> toJson() => {
        'pero_count': peroCount,
        'objection_words': objectionWords,
        'objections_received': objectionsReceived,
        'objections_made': objectionsMade,
        'filler_words': fillerWords,
      };

  bool get hasContent =>
      peroCount > 0 ||
      objectionWords.isNotEmpty ||
      objectionsReceived.isNotEmpty ||
      objectionsMade.isNotEmpty ||
      fillerWords.isNotEmpty;

  /// Get total count of all filler words
  int get totalFillerWords =>
      fillerWords.values.fold(0, (sum, count) => sum + count);

  /// Get total count of all objection words
  int get totalObjectionWords =>
      objectionWords.values.fold(0, (sum, count) => sum + count);
}

// ============ New 6-Competency Standard Models ============

/// X-ray of communication metrics
class Radiografia {
  final Map<String, int> muletillasDetectadas;
  final int muletillasTotal;
  final String muletillasFrecuencia;
  final String ratioHabla;
  final int palabrasUsuario;
  final int palabrasOtros;

  const Radiografia({
    this.muletillasDetectadas = const {},
    this.muletillasTotal = 0,
    this.muletillasFrecuencia = '',
    this.ratioHabla = '',
    this.palabrasUsuario = 0,
    this.palabrasOtros = 0,
  });

  factory Radiografia.fromJson(Map<String, dynamic> json) {
    return Radiografia(
      muletillasDetectadas:
          (json['muletillas_detectadas'] as Map<String, dynamic>?)
                  ?.map((k, v) => MapEntry(k, (v as num).toInt())) ??
              {},
      muletillasTotal: (json['muletillas_total'] as num?)?.toInt() ?? 0,
      muletillasFrecuencia: json['muletillas_frecuencia'] ?? '',
      ratioHabla: json['ratio_habla'] ?? '',
      palabrasUsuario: (json['palabras_usuario'] as num?)?.toInt() ?? 0,
      palabrasOtros: (json['palabras_otros'] as num?)?.toInt() ?? 0,
    );
  }

  int get totalPalabras => palabrasUsuario + palabrasOtros;
}

/// Question analysis
class PreguntasAnalysis {
  final List<String> preguntasUsuario;
  final List<String> preguntasOtros;
  final int totalUsuario;
  final int totalOtros;

  const PreguntasAnalysis({
    this.preguntasUsuario = const [],
    this.preguntasOtros = const [],
    this.totalUsuario = 0,
    this.totalOtros = 0,
  });

  factory PreguntasAnalysis.fromJson(Map<String, dynamic> json) {
    return PreguntasAnalysis(
      preguntasUsuario:
          (json['preguntas_usuario'] as List<dynamic>?)?.cast<String>() ?? [],
      preguntasOtros:
          (json['preguntas_otros'] as List<dynamic>?)?.cast<String>() ?? [],
      totalUsuario: (json['total_usuario'] as num?)?.toInt() ?? 0,
      totalOtros: (json['total_otros'] as num?)?.toInt() ?? 0,
    );
  }
}

/// User commitment/action from conversation
class AccionUsuario {
  final String descripcion;
  final bool tieneFecha;

  const AccionUsuario({this.descripcion = '', this.tieneFecha = false});

  factory AccionUsuario.fromJson(Map<String, dynamic> json) {
    return AccionUsuario(
      descripcion: json['descripcion'] ?? '',
      tieneFecha: json['tiene_fecha'] ?? false,
    );
  }
}

/// Unresolved topic
class TemaSinCerrar {
  final String tema;
  final String razon;

  const TemaSinCerrar({this.tema = '', this.razon = ''});

  factory TemaSinCerrar.fromJson(Map<String, dynamic> json) {
    return TemaSinCerrar(
      tema: json['tema'] ?? '',
      razon: json['razon'] ?? '',
    );
  }
}

/// Topics, commitments, and unresolved items
class TemasAnalysis {
  final List<String> temasTratados;
  final List<AccionUsuario> accionesUsuario;
  final List<TemaSinCerrar> temasSinCerrar;

  const TemasAnalysis({
    this.temasTratados = const [],
    this.accionesUsuario = const [],
    this.temasSinCerrar = const [],
  });

  factory TemasAnalysis.fromJson(Map<String, dynamic> json) {
    return TemasAnalysis(
      temasTratados:
          (json['temas_tratados'] as List<dynamic>?)?.cast<String>() ?? [],
      accionesUsuario: (json['acciones_usuario'] as List<dynamic>?)
              ?.map((e) => AccionUsuario.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      temasSinCerrar: (json['temas_sin_cerrar'] as List<dynamic>?)
              ?.map((e) => TemaSinCerrar.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Communication pattern analysis
class PatronAnalysis {
  final String actual;
  final String evolucion;
  final List<String> senales;
  final String queCambiaria;

  const PatronAnalysis({
    this.actual = '',
    this.evolucion = '',
    this.senales = const [],
    this.queCambiaria = '',
  });

  factory PatronAnalysis.fromJson(Map<String, dynamic> json) {
    return PatronAnalysis(
      actual: json['actual'] ?? '',
      evolucion: json['evolucion'] ?? '',
      senales: (json['senales'] as List<dynamic>?)?.cast<String>() ?? [],
      queCambiaria: json['que_cambiaria'] ?? '',
    );
  }
}

/// What you might not have noticed
class CommunicationInsight {
  final String dato;
  final String porQue;
  final String sugerencia;

  const CommunicationInsight({
    this.dato = '',
    this.porQue = '',
    this.sugerencia = '',
  });

  factory CommunicationInsight.fromJson(Map<String, dynamic> json) {
    return CommunicationInsight(
      dato: json['dato'] ?? '',
      porQue: json['por_que'] ?? '',
      sugerencia: json['sugerencia'] ?? '',
    );
  }
}

/// Competency score with metadata for UI rendering
class CompetencyScore {
  final String key;
  final String name;
  final double score;
  final Color color;

  const CompetencyScore({
    required this.key,
    required this.name,
    required this.score,
    required this.color,
  });
}

/// Standard competency colors
class CompetencyColors {
  static const clarity = Color(0xFF485DF4);
  static const structure = Color(0xFFFF8C42);
  static const vocabulario = Color(0xFF1BEA9A);
  static const empatia = Color(0xFFEF4444);
  static const objetivo = Color(0xFFFFD93D);
  static const adaptacion = Color(0xFF9B4DCA);
}

/// Communication feedback with 6 competency scores + rich analysis
class CommunicationFeedback {
  // Legacy fields
  final List<String> strengths;
  final List<String> areasToImprove;
  final CommunicationObservations observations;
  final String summary;
  final CommunicationCounters? counters;

  // 6 competency scores (0-10)
  final double overallScore;
  final double clarityScore;
  final double structureScore;
  final double vocabularioScore;
  final double empatiaScore;
  final double objetivoScore;
  final double adaptacionScore;

  // Rich analysis
  final String feedback;
  final Radiografia? radiografia;
  final PreguntasAnalysis? preguntas;
  final TemasAnalysis? temas;
  final PatronAnalysis? patron;
  final List<CommunicationInsight> insights;

  CommunicationFeedback({
    this.strengths = const [],
    this.areasToImprove = const [],
    CommunicationObservations? observations,
    this.summary = '',
    this.counters,
    this.overallScore = 0,
    this.clarityScore = 0,
    this.structureScore = 0,
    this.vocabularioScore = 0,
    this.empatiaScore = 0,
    this.objetivoScore = 0,
    this.adaptacionScore = 0,
    this.feedback = '',
    this.radiografia,
    this.preguntas,
    this.temas,
    this.patron,
    this.insights = const [],
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
      counters: json['counters'] != null
          ? CommunicationCounters.fromJson(json['counters'])
          : null,
      // 6 competency scores
      overallScore: (json['overall_score'] as num?)?.toDouble() ?? 0,
      clarityScore: (json['clarity'] as num?)?.toDouble() ?? 0,
      structureScore: (json['structure'] as num?)?.toDouble() ?? 0,
      vocabularioScore: (json['vocabulario'] as num?)?.toDouble() ?? 0,
      empatiaScore: (json['empatia'] as num?)?.toDouble() ?? 0,
      objetivoScore: (json['objetivo'] as num?)?.toDouble() ?? 0,
      adaptacionScore: (json['adaptacion'] as num?)?.toDouble() ?? 0,
      // Rich analysis
      feedback: json['feedback'] ?? '',
      radiografia: json['radiografia'] != null
          ? Radiografia.fromJson(json['radiografia'])
          : null,
      preguntas: json['preguntas'] != null
          ? PreguntasAnalysis.fromJson(json['preguntas'])
          : null,
      temas: json['temas'] != null
          ? TemasAnalysis.fromJson(json['temas'])
          : null,
      patron: json['patron'] != null
          ? PatronAnalysis.fromJson(json['patron'])
          : null,
      insights: (json['insights'] as List<dynamic>?)
              ?.map(
                  (e) => CommunicationInsight.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'strengths': strengths,
        'areas_to_improve': areasToImprove,
        'observations': observations.toJson(),
        'summary': summary,
        'counters': counters?.toJson(),
        'overall_score': overallScore,
        'clarity': clarityScore,
        'structure': structureScore,
        'vocabulario': vocabularioScore,
        'empatia': empatiaScore,
        'objetivo': objetivoScore,
        'adaptacion': adaptacionScore,
        'feedback': feedback,
      };

  /// True if this feedback has the new 6-competency scores
  bool get hasScores => overallScore > 0;

  /// True if this feedback has any content (legacy or new)
  bool get hasContent =>
      hasScores ||
      strengths.isNotEmpty ||
      areasToImprove.isNotEmpty ||
      observations.hasContent ||
      (counters?.hasContent ?? false);

  /// Get the 6 competency scores as a list for UI rendering
  List<CompetencyScore> get competencyScores => [
        CompetencyScore(
          key: 'clarity',
          name: 'Claridad',
          score: clarityScore,
          color: CompetencyColors.clarity,
        ),
        CompetencyScore(
          key: 'structure',
          name: 'Estructura',
          score: structureScore,
          color: CompetencyColors.structure,
        ),
        CompetencyScore(
          key: 'vocabulario',
          name: 'Vocabulario',
          score: vocabularioScore,
          color: CompetencyColors.vocabulario,
        ),
        CompetencyScore(
          key: 'empatia',
          name: 'Empatía',
          score: empatiaScore,
          color: CompetencyColors.empatia,
        ),
        CompetencyScore(
          key: 'objetivo',
          name: 'Objetivo',
          score: objetivoScore,
          color: CompetencyColors.objetivo,
        ),
        CompetencyScore(
          key: 'adaptacion',
          name: 'Adaptación',
          score: adaptacionScore,
          color: CompetencyColors.adaptacion,
        ),
      ];
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
