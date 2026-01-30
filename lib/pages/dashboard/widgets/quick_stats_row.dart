import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/dashboard_provider.dart';
import 'package:provider/provider.dart';

class QuickStatsRow extends StatelessWidget {
  const QuickStatsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<DashboardProvider>(
      builder: (context, provider, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              _buildStatCard(
                icon: FontAwesomeIcons.solidMessage,
                value: '${provider.todayConversationsCount}',
                label: l10n.conversations,
                color: const Color(0xFF485DF4),
              ),
              const SizedBox(width: 12),
              _buildStatCard(
                icon: FontAwesomeIcons.clock,
                value: l10n.minutesListened(provider.todayMinutesListened),
                label: l10n.listening,
                color: Colors.cyan,
              ),
              const SizedBox(width: 12),
              _buildStatCard(
                icon: FontAwesomeIcons.listCheck,
                value: l10n.tasksPending(provider.pendingTasksCount),
                label: l10n.toDos,
                color: Colors.orange,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F25),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            FaIcon(icon, size: 16, color: color),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
