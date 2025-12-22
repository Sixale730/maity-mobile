import 'package:flutter/material.dart';

/// Badge that displays similarity score as a percentage with color coding.
/// - Green (>80%): High relevance
/// - Yellow (50-80%): Medium relevance
/// - Grey (<50%): Low relevance
class SimilarityBadge extends StatelessWidget {
  final double similarity;
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  const SimilarityBadge({
    super.key,
    required this.similarity,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.borderRadius = 6,
  });

  Color get _color {
    if (similarity >= 0.8) {
      return const Color(0xFF22C55E); // Green
    } else if (similarity >= 0.5) {
      return const Color(0xFFEAB308); // Yellow
    } else {
      return const Color(0xFF6B7280); // Grey
    }
  }

  String get _label {
    final percentage = (similarity * 100).round();
    return '$percentage%';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Text(
        _label,
        style: TextStyle(
          color: _color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
