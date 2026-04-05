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
      _KpiData(FontAwesomeIcons.solidComments, const Color(0xFF6C9EFF), radiografia.ratioHabla, 'Ratio de habla'),
      _KpiData(FontAwesomeIcons.solidNoteSticky, const Color(0xFFFFD93D), radiografia.totalPalabras.toString(), 'Total palabras'),
      _KpiData(FontAwesomeIcons.solidUser, const Color(0xFF4ECDC4), radiografia.palabrasUsuario.toString(), 'Tus palabras'),
      _KpiData(FontAwesomeIcons.userGroup, const Color(0xFFCB6CE6), radiografia.palabrasOtros.toString(), 'Palabras otros'),
      _KpiData(FontAwesomeIcons.rotate, const Color(0xFFFF9500), radiografia.muletillasTotal.toString(), 'Total muletillas'),
      _KpiData(FontAwesomeIcons.chartBar, const Color(0xFF4ECDC4), radiografia.muletillasFrecuencia, 'Frecuencia muletillas'),
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
            SizedBox(width: 8),
            Text(
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
          childAspectRatio: 1.2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: kpis
              .map((kpi) => _buildKpiCard(
                    icon: kpi.icon,
                    iconColor: kpi.iconColor,
                    value: kpi.value,
                    label: kpi.label,
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _buildKpiCard({
    required IconData icon,
    required Color iconColor,
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
          FaIcon(icon, size: 18, color: iconColor),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            maxLines: 2,
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
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  const _KpiData(this.icon, this.iconColor, this.value, this.label);
}
