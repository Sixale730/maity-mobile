import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/models/daily_communication_report.dart';
import 'package:omi/providers/daily_report_provider.dart';
import 'package:provider/provider.dart';

class DailyReportCard extends StatelessWidget {
  const DailyReportCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DailyReportProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading && provider.latestReport == null) {
          return const SizedBox.shrink();
        }

        final report = provider.latestReport;
        if (report == null) {
          return _buildEmptyState(context);
        }

        return _buildReportCard(context, report);
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          Icon(FontAwesomeIcons.chartColumn, color: Colors.grey.shade600, size: 32),
          const SizedBox(height: 12),
          Text(
            l10n.noDailyReportYet,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade400, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildReportCard(BuildContext context, DailyCommunicationReport report) {
    final l10n = AppLocalizations.of(context)!;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2A2A2E), Color(0xFF1F1F25)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF485DF4).withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: title + date
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
                      child: const FaIcon(FontAwesomeIcons.chartColumn, color: Color(0xFF485DF4), size: 16),
                    ),
                    const SizedBox(width: 12),
                    Text(l10n.dailyEvaluation, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
                _buildTrendBadge(context, report.trend),
              ],
            ),
            const SizedBox(height: 8),
            Text(report.reportDate, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),

            const SizedBox(height: 20),

            // Overall score
            _buildOverallScore(context, report.scores),

            const SizedBox(height: 20),

            // Score dimensions
            _buildScoreBars(context, report.scores),

            const SizedBox(height: 16),

            // Stats row
            _buildStatsRow(context, report),

            // Summary
            if (report.dailySummary.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(l10n.dailySummary,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 8),
              Text(report.dailySummary,
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade300, height: 1.5)),
            ],

            // Strengths
            if (report.topStrengths.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildListSection(
                context,
                title: l10n.yourStrengths,
                items: report.topStrengths,
                icon: FontAwesomeIcons.check,
                color: Colors.green,
              ),
            ],

            // Areas to improve
            if (report.topAreasToImprove.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildListSection(
                context,
                title: l10n.areasToImprove,
                items: report.topAreasToImprove,
                icon: FontAwesomeIcons.lightbulb,
                color: Colors.orange,
              ),
            ],

            // Recommendations
            if (report.recommendations.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildListSection(
                context,
                title: l10n.dailyRecommendations,
                items: report.recommendations,
                icon: FontAwesomeIcons.bullseye,
                color: const Color(0xFF485DF4),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOverallScore(BuildContext context, DailyScores scores) {
    final l10n = AppLocalizations.of(context)!;
    final scoreColor = _getScoreColor(scores.overall);

    return Row(
      children: [
        Text(
          scores.overall.toStringAsFixed(1),
          style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: scoreColor, height: 1),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('/10', style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
            Text(l10n.overallScore, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ],
        ),
      ],
    );
  }

  Widget _buildScoreBars(BuildContext context, DailyScores scores) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        _buildScoreBar(l10n.clarity, scores.clarity, Colors.cyan),
        const SizedBox(height: 10),
        _buildScoreBar(l10n.structure, scores.structure, const Color(0xFF485DF4)),
        const SizedBox(height: 10),
        _buildScoreBar(l10n.callsToAction, scores.callsToAction, Colors.pink),
        const SizedBox(height: 10),
        _buildScoreBar(l10n.objectionHandling, scores.objectionHandling, Colors.amber),
      ],
    );
  }

  Widget _buildScoreBar(String label, double score, Color color) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (score / 10).clamp(0.0, 1.0),
              backgroundColor: Colors.grey.shade800,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 8,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 32,
          child: Text(
            score.toStringAsFixed(1),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow(BuildContext context, DailyCommunicationReport report) {
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _buildStatChip(FontAwesomeIcons.solidMessage, l10n.conversationsAnalyzedCount(report.conversationsAnalyzed)),
        if (report.totalDurationMinutes > 0)
          _buildStatChip(FontAwesomeIcons.clock, l10n.durationAnalyzed(report.totalDurationMinutes)),
        if (report.totalFillerCount > 0)
          _buildStatChip(FontAwesomeIcons.commentDots, l10n.fillerWordsCount(report.totalFillerCount)),
      ],
    );
  }

  Widget _buildStatChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(icon, size: 11, color: Colors.grey.shade500),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget _buildListSection(
    BuildContext context, {
    required String title,
    required List<String> items,
    required IconData icon,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            FaIcon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
        const SizedBox(height: 8),
        ...items.map((item) => Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 22),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.6), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(item, style: TextStyle(fontSize: 13, color: Colors.grey.shade300, height: 1.4)),
                  ),
                ],
              ),
            )),
      ],
    );
  }

  Color _getScoreColor(double score) {
    if (score >= 8.0) return Colors.green;
    if (score >= 6.0) return const Color(0xFF485DF4);
    if (score >= 4.0) return Colors.orange;
    return Colors.red;
  }
}
