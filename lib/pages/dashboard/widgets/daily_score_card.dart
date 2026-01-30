import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/models/daily_communication_report.dart';
import 'package:omi/providers/daily_report_provider.dart';
import 'package:provider/provider.dart';

class DailyScoreCard extends StatelessWidget {
  final VoidCallback? onTap;

  const DailyScoreCard({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<DailyReportProvider>(
      builder: (context, provider, child) {
        final report = provider.latestReport;
        if (report == null) {
          return _buildEmptyState(context);
        }
        return _buildScoreCard(context, report);
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF2A2A2E), Color(0xFF1F1F25)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          children: [
            Icon(FontAwesomeIcons.chartColumn, color: Colors.grey.shade600, size: 32),
            const SizedBox(height: 12),
            Text(
              l10n.noScoreYet,
              style: TextStyle(fontSize: 16, color: Colors.grey.shade400, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.noDailyReportYet,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCard(BuildContext context, DailyCommunicationReport report) {
    final l10n = AppLocalizations.of(context)!;
    final scores = report.scores;
    final scoreColor = _getScoreColor(scores.overall);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF2A2A2E), Color(0xFF1F1F25)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF485DF4).withValues(alpha: 0.3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF485DF4).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const FaIcon(FontAwesomeIcons.chartColumn, color: Color(0xFF485DF4), size: 14),
                      ),
                      const SizedBox(width: 10),
                      Text(l10n.todayScore, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  _buildTrendBadge(context, report.trend),
                ],
              ),
              const SizedBox(height: 16),

              // Score + bars row
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Big score
                  Column(
                    children: [
                      Text(
                        scores.overall.toStringAsFixed(1),
                        style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: scoreColor, height: 1),
                      ),
                      Text('/10', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
                    ],
                  ),
                  const SizedBox(width: 24),
                  // Score bars
                  Expanded(
                    child: Column(
                      children: [
                        _buildScoreBar(l10n.clarity, scores.clarity, Colors.cyan),
                        const SizedBox(height: 8),
                        _buildScoreBar(l10n.structure, scores.structure, const Color(0xFF485DF4)),
                        const SizedBox(height: 8),
                        _buildScoreBar(l10n.callsToAction, scores.callsToAction, Colors.pink),
                        const SizedBox(height: 8),
                        _buildScoreBar(l10n.objectionHandling, scores.objectionHandling, Colors.amber),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScoreBar(String label, double score, Color color) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500), overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (score / 10).clamp(0.0, 1.0),
              backgroundColor: Colors.grey.shade800,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 6,
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 24,
          child: Text(
            score.toStringAsFixed(1),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _buildTrendBadge(BuildContext context, DailyTrend trend) {
    final l10n = AppLocalizations.of(context)!;
    IconData icon;
    Color color;
    String text;

    switch (trend.trend) {
      case 'improving':
        icon = FontAwesomeIcons.arrowTrendUp;
        color = Colors.green;
        text = l10n.trendImproving;
        break;
      case 'stable':
        icon = FontAwesomeIcons.minus;
        color = Colors.grey;
        text = l10n.trendStable;
        break;
      case 'declining':
        icon = FontAwesomeIcons.arrowTrendDown;
        color = Colors.red;
        text = l10n.trendDeclining;
        break;
      default:
        icon = FontAwesomeIcons.star;
        color = const Color(0xFF485DF4);
        text = l10n.trendFirstReport;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
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
