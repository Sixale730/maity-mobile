import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:omi/models/communication_feedback.dart';

class CompetencyScoresWidget extends StatelessWidget {
  final List<CompetencyScore> scores;

  const CompetencyScoresWidget({
    super.key,
    required this.scores,
  });

  @override
  Widget build(BuildContext context) {
    if (scores.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            FaIcon(
              FontAwesomeIcons.chartBar,
              color: const Color(0xFF485DF4),
              size: 18,
            ),
            const SizedBox(width: 8),
            const Text(
              'Competencias de Comunicaci\u00f3n',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...List.generate(scores.length, (index) {
          final score = scores[index];
          return Padding(
            padding: EdgeInsets.only(bottom: index < scores.length - 1 ? 8 : 0),
            child: _CompetencyScoreCard(score: score),
          );
        }),
      ],
    );
  }
}

class _CompetencyScoreCard extends StatelessWidget {
  final CompetencyScore score;

  const _CompetencyScoreCard({required this.score});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: score.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                score.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                score.score.toStringAsFixed(1),
                style: TextStyle(
                  color: score.color,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (score.score / 10).clamp(0.0, 1.0),
              color: score.color,
              backgroundColor: Colors.grey[800],
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}
