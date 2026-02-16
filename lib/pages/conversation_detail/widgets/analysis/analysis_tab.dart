/// Main analysis tab that orchestrates all communication analysis sections.
/// Replaces the old SummaryTab + CommunicationFeedbackCard with the
/// 6-competency standard analysis.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/models/communication_feedback.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/competency_scores_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/hero_score_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/insights_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/muletillas_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/patron_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/preguntas_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/radiografia_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/strengths_areas_widget.dart';
import 'package:omi/pages/conversation_detail/widgets/analysis/temas_widget.dart';
import 'package:provider/provider.dart';

class AnalysisSection extends StatelessWidget {
  const AnalysisSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ConversationDetailProvider>(
      builder: (context, provider, child) {
        final feedback = provider.conversationFeedback;
        final isLoading = provider.isLoadingFeedback;
        final isRegenerating = provider.isRegeneratingFeedback;

        // Don't show anything for discarded conversations
        if (provider.conversation.discarded) {
          return const SizedBox.shrink();
        }

        // Loading state
        if (isLoading) {
          return Container(
            margin: const EdgeInsets.only(top: 24),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              ),
            ),
          );
        }

        // No feedback at all - show generate button
        if (feedback == null || !feedback.hasContent) {
          return _buildGeneratePrompt(context, provider, isRegenerating);
        }

        // Has new 6-competency scores - show full analysis
        if (feedback.hasScores) {
          return _buildFullAnalysis(context, feedback, provider, isRegenerating);
        }

        // Legacy feedback only - show legacy card with regenerate prompt
        return _buildLegacyWithUpgrade(context, feedback, provider, isRegenerating);
      },
    );
  }

  /// Full 6-competency analysis view
  Widget _buildFullAnalysis(
    BuildContext context,
    CommunicationFeedback feedback,
    ConversationDetailProvider provider,
    bool isRegenerating,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),

        // 1. Hero Score (gauge + overall + feedback text)
        HeroScoreWidget(feedback: feedback),

        const SizedBox(height: 16),

        // 2. Radiografía Rápida (KPIs grid)
        if (feedback.radiografia != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: RadiografiaWidget(radiografia: feedback.radiografia!),
          ),

        // 3. Competency Scores (6 bars)
        if (feedback.competencyScores.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: CompetencyScoresWidget(scores: feedback.competencyScores),
          ),

        // 4. Muletillas (horizontal bars)
        if (feedback.radiografia != null &&
            feedback.radiografia!.muletillasDetectadas.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: MuletillasWidget(radiografia: feedback.radiografia!),
          ),

        // 5. Preguntas (two columns)
        if (feedback.preguntas != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: PreguntasWidget(preguntas: feedback.preguntas!),
          ),

        // 6. Temas y Compromisos
        if (feedback.temas != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: TemasWidget(temas: feedback.temas!),
          ),

        // 7. Patrón de Comunicación
        if (feedback.patron != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: PatronWidget(patron: feedback.patron!),
          ),

        // 8. Insights
        if (feedback.insights.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: InsightsWidget(insights: feedback.insights),
          ),

        // 9. Strengths & Areas to Improve
        if (feedback.strengths.isNotEmpty || feedback.areasToImprove.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: StrengthsAreasWidget(
              strengths: feedback.strengths,
              areasToImprove: feedback.areasToImprove,
            ),
          ),

        // Regenerate button at bottom
        _buildRegenerateButton(context, provider, isRegenerating),
      ],
    );
  }

  /// Legacy feedback with upgrade prompt
  Widget _buildLegacyWithUpgrade(
    BuildContext context,
    CommunicationFeedback feedback,
    ConversationDetailProvider provider,
    bool isRegenerating,
  ) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),

        // Upgrade banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFF485DF4).withValues(alpha: 0.15),
                const Color(0xFF9B4DCA).withValues(alpha: 0.15),
              ],
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF485DF4).withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const FaIcon(FontAwesomeIcons.wandMagicSparkles,
                      size: 16, color: Color(0xFF485DF4)),
                  const SizedBox(width: 8),
                  Text(
                    l10n?.newAnalysisAvailable ??
                        'A more detailed analysis is available. Tap to regenerate.',
                    style: TextStyle(
                      color: Colors.grey[300],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildRegenerateButton(context, provider, isRegenerating),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Legacy strengths
        if (feedback.strengths.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: StrengthsAreasWidget(
              strengths: feedback.strengths,
              areasToImprove: feedback.areasToImprove,
            ),
          ),
      ],
    );
  }

  /// Generate prompt for conversations with no feedback
  Widget _buildGeneratePrompt(
    BuildContext context,
    ConversationDetailProvider provider,
    bool isRegenerating,
  ) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.psychology_outlined, size: 40, color: Colors.grey[600]),
          const SizedBox(height: 12),
          Text(
            l10n?.communicationFeedbackTitle ?? 'Communication Feedback',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n?.analyzeCommunicationStyle ??
                'Analyze your communication style in this conversation',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          ),
          const SizedBox(height: 16),
          _buildRegenerateButton(context, provider, isRegenerating,
              label: l10n?.generateFeedback ?? 'Generate Feedback'),
        ],
      ),
    );
  }

  Widget _buildRegenerateButton(
    BuildContext context,
    ConversationDetailProvider provider,
    bool isRegenerating, {
    String? label,
  }) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: isRegenerating
            ? null
            : () async {
                HapticFeedback.lightImpact();
                final success =
                    await provider.regenerateCommunicationFeedback();
                if (!success && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n?.couldNotRegenerateFeedback ??
                          'Could not regenerate feedback'),
                    ),
                  );
                }
              },
        icon: isRegenerating
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              )
            : const FaIcon(FontAwesomeIcons.arrowsRotate,
                size: 14, color: Color(0xFF485DF4)),
        label: Text(
          label ?? l10n?.regenerateAnalysis ?? 'Regenerate Analysis',
          style: const TextStyle(color: Color(0xFF485DF4), fontSize: 14),
        ),
      ),
    );
  }
}
