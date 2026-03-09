import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/models/communication_feedback.dart';

class PatronWidget extends StatelessWidget {
  final PatronAnalysis patron;

  const PatronWidget({super.key, required this.patron});

  @override
  Widget build(BuildContext context) {
    if (patron.actual.isEmpty &&
        patron.evolucion.isEmpty &&
        patron.senales.isEmpty &&
        patron.queCambiaria.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              FaIcon(
                FontAwesomeIcons.route,
                color: Color(0xFF9B4DCA),
                size: 18,
              ),
              SizedBox(width: 10),
              Text(
                'Patrón de Comunicación',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (patron.actual.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSubsection('Patrón actual', patron.actual),
          ],
          if (patron.evolucion.isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildSubsection('Evolución', patron.evolucion),
          ],
          if (patron.senales.isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildSubsectionTitle('Señales'),
            const SizedBox(height: 8),
            ...patron.senales.map(_buildBulletItem),
          ],
          if (patron.queCambiaria.isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildSubsectionTitle('Qué cambiar'),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.2),
                ),
              ),
              child: Text(
                patron.queCambiaria,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSubsectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildSubsection(String label, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSubsectionTitle(label),
        const SizedBox(height: 6),
        Text(
          text,
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildBulletItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 6, color: Colors.white54),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
