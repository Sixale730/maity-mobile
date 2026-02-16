import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/models/communication_feedback.dart';

class MuletillasWidget extends StatelessWidget {
  final Radiografia radiografia;

  const MuletillasWidget({super.key, required this.radiografia});

  @override
  Widget build(BuildContext context) {
    final muletillas = radiografia.muletillasDetectadas;
    if (muletillas.isEmpty) return const SizedBox.shrink();

    final sortedEntries = muletillas.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final maxCount = sortedEntries.first.value;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FaIcon(
                FontAwesomeIcons.commentDots,
                color: const Color(0xFF485DF4),
                size: 18,
              ),
              const SizedBox(width: 10),
              const Text(
                'Muletillas Detectadas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...sortedEntries.map((entry) => _buildBar(entry.key, entry.value, maxCount)),
        ],
      ),
    );
  }

  Widget _buildBar(String word, int count, int maxCount) {
    final fraction = maxCount > 0 ? count / maxCount : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              word,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    Container(
                      height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2E),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Container(
                      height: 20,
                      width: constraints.maxWidth * fraction,
                      decoration: BoxDecoration(
                        color: const Color(0xFF485DF4),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 30,
            child: Text(
              '$count',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
