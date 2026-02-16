import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Shows strengths and areas to improve lists.
class StrengthsAreasWidget extends StatelessWidget {
  final List<String> strengths;
  final List<String> areasToImprove;

  const StrengthsAreasWidget({
    super.key,
    required this.strengths,
    required this.areasToImprove,
  });

  @override
  Widget build(BuildContext context) {
    if (strengths.isEmpty && areasToImprove.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Strengths section
        if (strengths.isNotEmpty)
          _buildSection(
            title: 'Fortalezas',
            icon: FontAwesomeIcons.check,
            iconColor: Colors.green,
            bulletColor: Colors.green,
            items: strengths,
          ),

        if (strengths.isNotEmpty && areasToImprove.isNotEmpty)
          const SizedBox(height: 16),

        // Areas to improve section
        if (areasToImprove.isNotEmpty)
          _buildSection(
            title: 'Areas de Mejora',
            icon: FontAwesomeIcons.lightbulb,
            iconColor: Colors.amber,
            bulletColor: Colors.amber,
            items: areasToImprove,
          ),
      ],
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Color bulletColor,
    required List<String> items,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FaIcon(icon, size: 12, color: iconColor),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: bulletColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item,
                        style: TextStyle(color: Colors.grey[300], fontSize: 14),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
