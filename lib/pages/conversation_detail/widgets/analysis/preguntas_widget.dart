import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/models/communication_feedback.dart';

class PreguntasWidget extends StatelessWidget {
  final PreguntasAnalysis preguntas;

  const PreguntasWidget({super.key, required this.preguntas});

  @override
  Widget build(BuildContext context) {
    if (preguntas.preguntasUsuario.isEmpty && preguntas.preguntasOtros.isEmpty) {
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
          Row(
            children: [
              FaIcon(
                FontAwesomeIcons.circleQuestion,
                color: Colors.amber,
                size: 18,
              ),
              const SizedBox(width: 10),
              const Text(
                'Análisis de Preguntas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildColumn(
                  'Tus preguntas (${preguntas.totalUsuario})',
                  preguntas.preguntasUsuario,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildColumn(
                  'Preguntas de otros (${preguntas.totalOtros})',
                  preguntas.preguntasOtros,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildColumn(String header, List<String> questions) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          header,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (questions.isEmpty)
          const Text(
            'Ninguna',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          )
        else
          ...questions.asMap().entries.map((entry) {
            final index = entry.key + 1;
            final question = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '$index. $question',
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 13,
                ),
              ),
            );
          }),
      ],
    );
  }
}
