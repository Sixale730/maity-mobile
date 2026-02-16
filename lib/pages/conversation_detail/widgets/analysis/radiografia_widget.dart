import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/models/communication_feedback.dart';

class RadiografiaWidget extends StatelessWidget {
  final Radiografia radiografia;

  const RadiografiaWidget({super.key, required this.radiografia});

  bool get _isEmpty =>
      radiografia.ratioHabla.isEmpty &&
      radiografia.totalPalabras == 0 &&
      radiografia.palabrasUsuario == 0 &&
      radiografia.palabrasOtros == 0 &&
      radiografia.muletillasTotal == 0 &&
      radiografia.muletillasFrecuencia.isEmpty;

  @override
  Widget build(BuildContext context) {
    if (_isEmpty) return const SizedBox.shrink();

    final kpis = [
      _KpiData('\u{1F5E3}\u{FE0F}', radiografia.ratioHabla, 'Ratio de habla'),
      _KpiData('\u{1F4DD}', radiografia.totalPalabras.toString(), 'Total palabras'),
      _KpiData('\u{1F464}', radiografia.palabrasUsuario.toString(), 'Tus palabras'),
      _KpiData('\u{1F465}', radiografia.palabrasOtros.toString(), 'Palabras otros'),
      _KpiData('\u{1F504}', radiografia.muletillasTotal.toString(), 'Total muletillas'),
      _KpiData('\u{1F4CA}', radiografia.muletillasFrecuencia, 'Frecuencia muletillas'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title
        const Row(
          children: [
            FaIcon(
              FontAwesomeIcons.stethoscope,
              color: Colors.teal,
              size: 16,
            ),
            const SizedBox(width: 8),
            const Text(
              'Radiografia Rapida',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // KPI grid - 2 columns
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: kpis
              .map((kpi) => _buildKpiCard(
                    emoji: kpi.emoji,
                    value: kpi.value,
                    label: kpi.label,
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _buildKpiCard({
    required String emoji,
    required String value,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiData {
  final String emoji;
  final String value;
  final String label;

  const _KpiData(this.emoji, this.value, this.label);
}
