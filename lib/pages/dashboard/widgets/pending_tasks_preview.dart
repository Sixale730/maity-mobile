import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:provider/provider.dart';

class PendingTasksPreview extends StatelessWidget {
  const PendingTasksPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<ActionItemsProvider>(
      builder: (context, provider, _) {
        final tasks = provider.todoItems.take(3).toList();

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l10n.pendingTasks, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade400)),
                  if (tasks.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        context.read<HomeProvider>().setIndex(3);
                      },
                      child: Text(l10n.viewAll, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF485DF4))),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (tasks.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F1F25),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    children: [
                      Icon(FontAwesomeIcons.circleCheck, color: Colors.grey.shade700, size: 24),
                      const SizedBox(height: 8),
                      Text(l10n.noPendingTasks, style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                    ],
                  ),
                )
              else
                ...tasks.map((task) => _buildTaskItem(context, task, provider)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTaskItem(BuildContext context, dynamic task, ActionItemsProvider provider) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              provider.updateActionItemState(task, true);
            },
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.grey.shade600, width: 1.5),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              task.description,
              style: const TextStyle(fontSize: 14, color: Colors.white),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
