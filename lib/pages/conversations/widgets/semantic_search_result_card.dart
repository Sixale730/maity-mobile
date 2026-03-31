import 'package:flutter/material.dart';
import 'package:omi/services/omi_supabase_service.dart';
import 'package:omi/widgets/emoji_text.dart';
import 'package:omi/ui/atoms/similarity_badge.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/other/time_utils.dart';
import 'package:omi/widgets/extensions/string.dart';

/// Card widget for displaying semantic search results with similarity score.
class SemanticSearchResultCard extends StatelessWidget {
  final SemanticSearchResult result;
  final int index;
  final VoidCallback? onTap;

  const SemanticSearchResultCard({
    super.key,
    required this.result,
    required this.index,
    this.onTap,
  });

  Color _getTagColor() {
    switch (result.category.toLowerCase()) {
      case 'personal':
        return Colors.blue.withValues(alpha: 0.2);
      case 'work':
        return Colors.green.withValues(alpha: 0.2);
      case 'education':
        return Colors.orange.withValues(alpha: 0.2);
      case 'health':
        return Colors.red.withValues(alpha: 0.2);
      case 'finance':
        return const Color(0xFF485DF4).withValues(alpha: 0.2);
      case 'travel':
        return Colors.teal.withValues(alpha: 0.2);
      case 'entertainment':
        return Colors.pink.withValues(alpha: 0.2);
      default:
        return Colors.grey.withValues(alpha: 0.2);
    }
  }

  Color _getTagTextColor() {
    switch (result.category.toLowerCase()) {
      case 'personal':
        return Colors.blue.shade300;
      case 'work':
        return Colors.green.shade300;
      case 'education':
        return Colors.orange.shade300;
      case 'health':
        return Colors.red.shade300;
      case 'finance':
        return const Color(0xFF8A9AF7); // Lighter shade of #485DF4
      case 'travel':
        return Colors.teal.shade300;
      case 'entertainment':
        return Colors.pink.shade300;
      default:
        return Colors.grey.shade300;
    }
  }

  String _getDuration() {
    if (result.durationSeconds <= 0) return '';
    return secondsToCompactDuration(result.durationSeconds);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, left: 16, right: 16),
        child: Container(
          width: double.maxFinite,
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F25),
            borderRadius: BorderRadius.circular(24.0),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context),
                const SizedBox(height: 16),
                _buildBody(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.0, right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Emoji + Tag
          Flexible(
            fit: FlexFit.tight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (result.emoji.isNotEmpty)
                  EmojiText(result.emoji, size: 22),
                if (result.category.isNotEmpty) const SizedBox(width: 8),
                if (result.category.isNotEmpty)
                  Flexible(
                    child: Container(
                      decoration: BoxDecoration(
                        color: _getTagColor(),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        result.category.capitalize(),
                        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                              color: _getTagTextColor(),
                            ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // Similarity Badge
          SimilarityBadge(similarity: result.similarity),

          const SizedBox(width: 8),

          // Timestamp + Duration
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  dateTimeFormat(
                    'h:mm a',
                    result.startedAt ?? result.createdAt,
                  ),
                  style: const TextStyle(color: Color(0xFF6A6B71), fontSize: 14),
                  maxLines: 1,
                ),
                if (_getDuration().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF35343B),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _getDuration(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                        maxLines: 1,
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

  Widget _buildBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          result.title.decodeString,
          style: Theme.of(context).textTheme.titleLarge,
          maxLines: 1,
        ),
        const SizedBox(height: 8),
        Text(
          result.overview.decodeString,
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: Colors.grey.shade300,
                height: 1.3,
              ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
