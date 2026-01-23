import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/utils/ui_guidelines.dart';
import 'package:provider/provider.dart';

/// List of available conversation categories
const List<String> conversationCategories = [
  'personal',
  'education',
  'health',
  'finance',
  'legal',
  'philosophy',
  'spiritual',
  'science',
  'entrepreneurship',
  'parenting',
  'romantic',
  'travel',
  'inspiration',
  'technology',
  'business',
  'social',
  'work',
  'sports',
  'politics',
  'literature',
  'history',
  'architecture',
  'music',
  'weather',
  'news',
  'entertainment',
  'psychology',
  'design',
  'family',
  'economics',
  'environment',
  'other',
];

class CategoryFilterBar extends StatefulWidget {
  const CategoryFilterBar({super.key});

  @override
  State<CategoryFilterBar> createState() => _CategoryFilterBarState();
}

class _CategoryFilterBarState extends State<CategoryFilterBar> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _chipKeys = {};

  @override
  void initState() {
    super.initState();
    // Initialize keys for all categories plus "All" and "Starred"
    _chipKeys['all'] = GlobalKey();
    _chipKeys['starred'] = GlobalKey();
    for (var category in conversationCategories) {
      _chipKeys[category] = GlobalKey();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelectedChip(String? selectedKey) {
    if (selectedKey == null) return;
    final key = _chipKeys[selectedKey];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.3,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Consumer<ConversationProvider>(
      builder: (context, provider, child) {
        // Get unique categories from current conversations
        final Set<String> availableCategories = {};
        for (var convo in provider.conversations) {
          final category = convo.structured.category.toLowerCase();
          if (category.isNotEmpty && conversationCategories.contains(category)) {
            availableCategories.add(category);
          }
        }

        // Sort categories alphabetically
        final sortedCategories = availableCategories.toList()..sort();

        return Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // "All" chip
                _FilterChip(
                  key: _chipKeys['all'],
                  label: l10n?.filterAll ?? 'All',
                  isSelected: provider.selectedCategory == null && !provider.showStarredOnly,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    provider.clearAllFilters();
                    _scrollToSelectedChip('all');
                  },
                ),
                const SizedBox(width: 8),
                // "Starred" chip
                _FilterChip(
                  key: _chipKeys['starred'],
                  label: l10n?.filterStarred ?? 'Starred',
                  icon: FontAwesomeIcons.solidStar,
                  iconColor: Colors.amber,
                  isSelected: provider.showStarredOnly,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    provider.toggleStarredFilter();
                    if (provider.showStarredOnly) {
                      _scrollToSelectedChip('starred');
                    }
                  },
                ),
                // Category chips
                ...sortedCategories.map((category) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _FilterChip(
                      key: _chipKeys[category],
                      label: getLocalizedCategory(context, category),
                      isSelected: provider.selectedCategory == category,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        if (provider.selectedCategory == category) {
                          provider.setCategoryFilter(null);
                        } else {
                          provider.setCategoryFilter(category);
                          _scrollToSelectedChip(category);
                        }
                      },
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterChip({
    super.key,
    required this.label,
    this.icon,
    this.iconColor,
    required this.isSelected,
    required this.onTap,
  });

  static const Color _selectedColor = Color(0xFF485DF4);
  static const Color _unselectedColor = Color(0xFF35343B);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? _selectedColor : _unselectedColor,
          borderRadius: BorderRadius.circular(AppStyles.radiusCircular),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              FaIcon(
                icon,
                size: 12,
                color: iconColor ?? (isSelected ? Colors.white : Colors.white70),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
