import 'package:omi/services/speaker/speaker_types.dart';

// ---------------------------------------------------------------------------
// Correction gate thresholds
// ---------------------------------------------------------------------------

/// Only correct segments with acoustic confidence below this.
const double kCorrectionGateMax = 0.60;

/// A correction must be at least this confident to be applied.
const double kCorrectionGateMin = 0.65;

// Per-rule confidence values
const double _kQuestionAnswerConf = 0.70;
const double _kSelfReferenceConf = 0.80;
const double _kIsolatedSpeakerConf = 0.75;
const double _kTurnRhythmConf = 0.65;
const double _kVocabularyConf = 0.65;

// Rule-specific parameters
const double _kTurnRhythmDominance = 0.60;
const double _kTurnRhythmLowConf = 0.50;
const double _kIsolatedGapMaxSec = 5.0;
const int _kTurnRhythmWindow = 5;
const int _kMinExclusiveWords = 2;
const int _kMinWordLengthForVocab = 4;

// ---------------------------------------------------------------------------
// Spanish pronouns for self-reference rule
// ---------------------------------------------------------------------------

/// First-person markers → likely the user (speaker 0).
const Set<String> kFirstPersonMarkers = {
  'yo',
  'mi',
  'mí',
  'me',
  'nos',
  'nosotros',
  'nosotras',
  'nuestro',
  'nuestra',
  'nuestros',
  'nuestras',
  'mi empresa',
  'mi equipo',
  'mi trabajo',
  'mi negocio',
  'mi experiencia',
  'mi cliente',
};

/// Second-person markers → likely NOT the user.
const Set<String> kSecondPersonMarkers = {
  'usted',
  'ustedes',
  'su empresa',
  'su equipo',
  'su trabajo',
  'su negocio',
  'su experiencia',
  'su cliente',
};

/// Spanish stopwords excluded from vocabulary consistency analysis.
const Set<String> kSpanishStopwords = {
  'que', 'para', 'como', 'pero', 'más', 'este', 'esta', 'estos', 'estas',
  'una', 'uno', 'unos', 'unas', 'por', 'con', 'sin', 'sobre', 'entre',
  'cuando', 'donde', 'porque', 'también', 'entonces', 'después', 'antes',
  'todo', 'toda', 'todos', 'todas', 'otro', 'otra', 'otros', 'otras',
  'bien', 'muy', 'aquí', 'ahí', 'así', 'cada', 'algo', 'nada',
  'puede', 'tiene', 'hace', 'dice', 'está', 'están', 'sido', 'será',
  'del', 'las', 'los', 'les', 'sus', 'hay', 'son', 'era',
};

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// Apply 5 linguistic heuristic corrections to scored transcript segments.
///
/// Only corrects segments with confidence < [kCorrectionGateMax]. Each
/// correction must have confidence >= [kCorrectionGateMin]. A segment
/// is corrected at most once (first matching rule wins).
///
/// Rules applied in order:
/// 1. Question-Answer pattern
/// 2. Self-reference (Spanish first/second person)
/// 3. Isolated speaker (sandwich pattern)
/// 4. Turn rhythm (dominant speaker in window)
/// 5. Vocabulary consistency (exclusive words)
List<CorrectionRecord> applyHeuristicCorrections(
    List<ScoredSegment> segments) {
  if (segments.length < 2) return [];

  final corrected = <int>{}; // Indices already corrected
  final records = <CorrectionRecord>[];

  // Apply rules in priority order
  records.addAll(_ruleQuestionAnswer(segments, corrected));
  records.addAll(_ruleSelfReference(segments, corrected));
  records.addAll(_ruleIsolatedSpeaker(segments, corrected));
  records.addAll(_ruleTurnRhythm(segments, corrected));
  records.addAll(_ruleVocabularyConsistency(segments, corrected));

  return records;
}

// ---------------------------------------------------------------------------
// Rule 1: Question-Answer
// ---------------------------------------------------------------------------

/// If a segment ends with "?" and the next segment has the same speaker
/// with low confidence, the next segment likely belongs to a different speaker.
List<CorrectionRecord> _ruleQuestionAnswer(
    List<ScoredSegment> segments, Set<int> corrected) {
  final records = <CorrectionRecord>[];

  for (var i = 0; i < segments.length - 1; i++) {
    final curr = segments[i];
    final next = segments[i + 1];

    if (!curr.text.trimRight().endsWith('?')) continue;
    if (next.confidence >= kCorrectionGateMax) continue;
    if (corrected.contains(i + 1)) continue;
    if (curr.speakerId != next.speakerId) continue;

    // Assign to a different speaker
    final newSpeaker = curr.speakerId == 0 ? 1 : 0;

    if (_kQuestionAnswerConf >= kCorrectionGateMin) {
      records.add(CorrectionRecord(
        segmentIndex: i + 1,
        originalSpeaker: next.speakerId,
        correctedSpeaker: newSpeaker,
        correctionSource: 'heuristic',
        ruleName: 'question_answer',
        correctionConfidence: _kQuestionAnswerConf,
      ));
      corrected.add(i + 1);
    }
  }
  return records;
}

// ---------------------------------------------------------------------------
// Rule 2: Self-Reference (Spanish)
// ---------------------------------------------------------------------------

/// Detect first-person and second-person markers in Spanish text.
/// First-person → likely user (speaker 0). Second-person → likely non-user.
List<CorrectionRecord> _ruleSelfReference(
    List<ScoredSegment> segments, Set<int> corrected) {
  final records = <CorrectionRecord>[];

  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    if (seg.confidence >= kCorrectionGateMax) continue;
    if (corrected.contains(i)) continue;

    final textLower = seg.text.toLowerCase();

    var firstPersonHits = 0;
    var secondPersonHits = 0;

    for (final marker in kFirstPersonMarkers) {
      if (textLower.contains(marker)) firstPersonHits++;
    }
    for (final marker in kSecondPersonMarkers) {
      if (textLower.contains(marker)) secondPersonHits++;
    }

    final totalHits = firstPersonHits + secondPersonHits;
    if (totalHits == 0) continue;

    int? suggestedSpeaker;
    if (firstPersonHits > secondPersonHits &&
        firstPersonHits / totalHits > 0.5) {
      suggestedSpeaker = 0; // User
    } else if (secondPersonHits > firstPersonHits &&
        secondPersonHits / totalHits > 0.5) {
      suggestedSpeaker = seg.speakerId == 0 ? 1 : 0; // Non-user
    }

    if (suggestedSpeaker != null &&
        suggestedSpeaker != seg.speakerId &&
        _kSelfReferenceConf >= kCorrectionGateMin) {
      records.add(CorrectionRecord(
        segmentIndex: i,
        originalSpeaker: seg.speakerId,
        correctedSpeaker: suggestedSpeaker,
        correctionSource: 'heuristic',
        ruleName: 'self_reference',
        correctionConfidence: _kSelfReferenceConf,
      ));
      corrected.add(i);
    }
  }
  return records;
}

// ---------------------------------------------------------------------------
// Rule 3: Isolated Speaker (sandwich pattern)
// ---------------------------------------------------------------------------

/// If prev and next have the same speaker but curr has a different one,
/// and gaps are small, curr is likely a mis-assignment.
List<CorrectionRecord> _ruleIsolatedSpeaker(
    List<ScoredSegment> segments, Set<int> corrected) {
  final records = <CorrectionRecord>[];

  for (var i = 1; i < segments.length - 1; i++) {
    final prev = segments[i - 1];
    final curr = segments[i];
    final next = segments[i + 1];

    if (curr.confidence >= kCorrectionGateMax) continue;
    if (corrected.contains(i)) continue;

    // Sandwich: prev == next != curr
    if (prev.speakerId != next.speakerId) continue;
    if (curr.speakerId == prev.speakerId) continue;

    // Check gaps
    final gapBefore = curr.startTime - prev.endTime;
    final gapAfter = next.startTime - curr.endTime;
    if (gapBefore > _kIsolatedGapMaxSec || gapAfter > _kIsolatedGapMaxSec) {
      continue;
    }

    if (_kIsolatedSpeakerConf >= kCorrectionGateMin) {
      records.add(CorrectionRecord(
        segmentIndex: i,
        originalSpeaker: curr.speakerId,
        correctedSpeaker: prev.speakerId,
        correctionSource: 'heuristic',
        ruleName: 'isolated_speaker',
        correctionConfidence: _kIsolatedSpeakerConf,
      ));
      corrected.add(i);
    }
  }
  return records;
}

// ---------------------------------------------------------------------------
// Rule 4: Turn Rhythm
// ---------------------------------------------------------------------------

/// In a sliding window of 5 segments, if a dominant speaker has >= 60%
/// and the current segment has very low confidence (< 0.50), reassign
/// to the dominant speaker.
List<CorrectionRecord> _ruleTurnRhythm(
    List<ScoredSegment> segments, Set<int> corrected) {
  final records = <CorrectionRecord>[];

  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    if (seg.confidence >= _kTurnRhythmLowConf) continue;
    if (corrected.contains(i)) continue;

    // Build window around i
    final windowStart = (i - _kTurnRhythmWindow ~/ 2).clamp(0, segments.length);
    final windowEnd =
        (i + _kTurnRhythmWindow ~/ 2 + 1).clamp(0, segments.length);

    final speakerCounts = <int, int>{};
    var windowSize = 0;
    for (var j = windowStart; j < windowEnd; j++) {
      if (j == i) continue; // Exclude the segment itself
      speakerCounts[segments[j].speakerId] =
          (speakerCounts[segments[j].speakerId] ?? 0) + 1;
      windowSize++;
    }

    if (windowSize == 0) continue;

    // Find dominant speaker
    int? dominantSpeaker;
    var dominantCount = 0;
    for (final entry in speakerCounts.entries) {
      if (entry.value > dominantCount) {
        dominantCount = entry.value;
        dominantSpeaker = entry.key;
      }
    }

    if (dominantSpeaker == null) continue;
    if (dominantCount / windowSize < _kTurnRhythmDominance) continue;
    if (dominantSpeaker == seg.speakerId) continue;

    if (_kTurnRhythmConf >= kCorrectionGateMin) {
      records.add(CorrectionRecord(
        segmentIndex: i,
        originalSpeaker: seg.speakerId,
        correctedSpeaker: dominantSpeaker,
        correctionSource: 'heuristic',
        ruleName: 'turn_rhythm',
        correctionConfidence: _kTurnRhythmConf,
      ));
      corrected.add(i);
    }
  }
  return records;
}

// ---------------------------------------------------------------------------
// Rule 5: Vocabulary Consistency
// ---------------------------------------------------------------------------

/// Build vocabulary per speaker from high-confidence segments.
/// If a low-confidence segment contains >= 2 words exclusive to another
/// speaker, reassign it.
List<CorrectionRecord> _ruleVocabularyConsistency(
    List<ScoredSegment> segments, Set<int> corrected) {
  final records = <CorrectionRecord>[];

  // Build per-speaker vocabulary from high-confidence segments
  // Map<speakerId, Map<word, count>>
  final speakerVocab = <int, Map<String, int>>{};

  for (final seg in segments) {
    if (seg.confidence < kHighConfThreshold) continue;

    final words = _tokenize(seg.text);
    final vocab = speakerVocab.putIfAbsent(seg.speakerId, () => {});
    for (final word in words) {
      if (word.length < _kMinWordLengthForVocab) continue;
      if (kSpanishStopwords.contains(word)) continue;
      vocab[word] = (vocab[word] ?? 0) + 1;
    }
  }

  if (speakerVocab.length < 2) return records;

  // Find exclusive words: words that appear >= 2 times in exactly one speaker
  final exclusiveWords = <String, int>{}; // word → speakerId
  final allWords = <String>{};
  for (final entry in speakerVocab.entries) {
    allWords.addAll(entry.value.keys);
  }

  for (final word in allWords) {
    int? ownerSpeaker;
    var isExclusive = true;
    for (final entry in speakerVocab.entries) {
      final count = entry.value[word] ?? 0;
      if (count >= 2) {
        if (ownerSpeaker == null) {
          ownerSpeaker = entry.key;
        } else {
          isExclusive = false;
          break;
        }
      }
    }
    if (isExclusive && ownerSpeaker != null) {
      exclusiveWords[word] = ownerSpeaker;
    }
  }

  if (exclusiveWords.isEmpty) return records;

  // Check low-confidence segments for exclusive word matches
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    if (seg.confidence >= kCorrectionGateMax) continue;
    if (corrected.contains(i)) continue;

    final words = _tokenize(seg.text);

    // Count exclusive word hits per speaker
    final hits = <int, int>{};
    for (final word in words) {
      final owner = exclusiveWords[word];
      if (owner != null) {
        hits[owner] = (hits[owner] ?? 0) + 1;
      }
    }

    // Find speaker with most hits
    int? bestSpeaker;
    var bestHits = 0;
    for (final entry in hits.entries) {
      if (entry.value > bestHits) {
        bestHits = entry.value;
        bestSpeaker = entry.key;
      }
    }

    if (bestSpeaker == null) continue;
    if (bestHits < _kMinExclusiveWords) continue;
    if (bestSpeaker == seg.speakerId) continue;

    if (_kVocabularyConf >= kCorrectionGateMin) {
      records.add(CorrectionRecord(
        segmentIndex: i,
        originalSpeaker: seg.speakerId,
        correctedSpeaker: bestSpeaker,
        correctionSource: 'heuristic',
        ruleName: 'vocabulary_consistency',
        correctionConfidence: _kVocabularyConf,
      ));
      corrected.add(i);
    }
  }
  return records;
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

/// Simple word tokenizer: lowercase, strip punctuation, split on whitespace.
List<String> _tokenize(String text) {
  return text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\wáéíóúüñ\s]'), '')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
}
