import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/models/communication_feedback.dart';

/// Shows up to 3 "what you might not have noticed" insight cards.
class InsightsWidget extends StatelessWidget {
  final List<CommunicationInsight> insights;

  const InsightsWidget({super.key, required this.insights});

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();

    final displayInsights = insights.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title
        const Row(
          children: [
            FaIcon(
              FontAwesomeIcons.lightbulb,
              size: 14,
              color: Colors.amber,
            ),
            SizedBox(width: 8),
            Text(
              'Lo que quizas no notaste',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Insight cards
        ...List.generate(displayInsights.length, (index) {
          final insight = displayInsights[index];
          return Padding(
            padding: EdgeInsets.only(bottom: index < displayInsights.length - 1 ? 12 : 0),
            child: _InsightCard(insight: insight),
          );
        }),
      ],
    );
  }
}

class _InsightCard extends StatelessWidget {
  final CommunicationInsight insight;

  const _InsightCard({required this.insight});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dato (main insight text)
          if (insight.dato.isNotEmpty)
            Text(
              insight.dato,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),

          // Por que (reason)
          if (insight.porQue.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Por que?',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              insight.porQue,
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 13,
              ),
            ),
          ],

          // Sugerencia (suggestion in colored container)
          if (insight.sugerencia.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF485DF4).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: FaIcon(
                      FontAwesomeIcons.lightbulb,
                      size: 11,
                      color: const Color(0xFF485DF4).withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      insight.sugerencia,
                      style: TextStyle(
                        color: Colors.grey[300],
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
