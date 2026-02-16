import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/models/communication_feedback.dart';

class TemasWidget extends StatelessWidget {
  final TemasAnalysis temas;

  const TemasWidget({super.key, required this.temas});

  @override
  Widget build(BuildContext context) {
    if (temas.temasTratados.isEmpty &&
        temas.accionesUsuario.isEmpty &&
        temas.temasSinCerrar.isEmpty) {
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
                FontAwesomeIcons.listCheck,
                color: Colors.green,
                size: 18,
              ),
              const SizedBox(width: 10),
              const Text(
                'Temas y Compromisos',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (temas.temasTratados.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSubsectionTitle('Temas tratados'),
            const SizedBox(height: 8),
            ...temas.temasTratados.map(_buildBulletItem),
          ],
          if (temas.accionesUsuario.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSubsectionTitle('Tus compromisos'),
            const SizedBox(height: 8),
            ...temas.accionesUsuario.map(_buildAccionItem),
          ],
          if (temas.temasSinCerrar.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSubsectionTitle('Temas sin cerrar'),
            const SizedBox(height: 8),
            ...temas.temasSinCerrar.map(_buildTemaSinCerrarItem),
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

  Widget _buildAccionItem(AccionUsuario accion) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 6, color: Colors.white54),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    accion.descripcion,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: accion.tieneFecha
                        ? Colors.green.withValues(alpha: 0.2)
                        : Colors.orange.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    accion.tieneFecha ? 'Con fecha' : 'Sin fecha',
                    style: TextStyle(
                      color: accion.tieneFecha ? Colors.green : Colors.orange,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTemaSinCerrarItem(TemaSinCerrar tema) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 6, color: Colors.white54),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tema.tema,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (tema.razon.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    tema.razon,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
