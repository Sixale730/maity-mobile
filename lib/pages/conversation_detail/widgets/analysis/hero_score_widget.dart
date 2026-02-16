import 'dart:math';

import 'package:flutter/material.dart';
import 'package:omi/models/communication_feedback.dart';

class HeroScoreWidget extends StatelessWidget {
  final CommunicationFeedback feedback;

  const HeroScoreWidget({super.key, required this.feedback});

  @override
  Widget build(BuildContext context) {
    final scoreColor = _getScoreColor(feedback.overallScore);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section title
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scoreColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.speed, color: scoreColor, size: 16),
              ),
              const SizedBox(width: 10),
              const Text(
                'Score General',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Semicircular gauge
          Center(
            child: SizedBox(
              width: 200,
              height: 120,
              child: CustomPaint(
                painter: _SemicircularGaugePainter(
                  score: feedback.overallScore,
                  maxScore: 10,
                  scoreColor: scoreColor,
                  trackColor: Colors.white.withValues(alpha: 0.08),
                  strokeWidth: 12,
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        feedback.overallScore.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.bold,
                          color: scoreColor,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '/10',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Feedback text
          if (feedback.feedback.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              feedback.feedback,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade400,
                fontStyle: FontStyle.italic,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Color _getScoreColor(double score) {
    if (score >= 8.0) return Colors.green;
    if (score >= 6.0) return const Color(0xFF485DF4);
    if (score >= 4.0) return Colors.orange;
    return Colors.red;
  }
}

class _SemicircularGaugePainter extends CustomPainter {
  final double score;
  final double maxScore;
  final Color scoreColor;
  final Color trackColor;
  final double strokeWidth;

  _SemicircularGaugePainter({
    required this.score,
    required this.maxScore,
    required this.scoreColor,
    required this.trackColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height);
    final radius = min(size.width / 2, size.height) - strokeWidth / 2;

    // Draw track (background arc from 180 to 0 degrees)
    final trackPaint = Paint()
      ..color = trackColor
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromCircle(center: center, radius: radius);

    // Arc from pi (180 degrees) sweeping -pi (to 0 degrees)
    canvas.drawArc(rect, pi, -pi, false, trackPaint);

    // Draw score arc
    final progress = (score / maxScore).clamp(0.0, 1.0);
    if (progress > 0) {
      final scorePaint = Paint()
        ..color = scoreColor
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final sweepAngle = -pi * progress;
      canvas.drawArc(rect, pi, sweepAngle, false, scorePaint);
    }
  }

  @override
  bool shouldRepaint(_SemicircularGaugePainter oldDelegate) {
    return oldDelegate.score != score ||
        oldDelegate.scoreColor != scoreColor ||
        oldDelegate.trackColor != trackColor;
  }
}
