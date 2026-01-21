import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/feedback_service.dart';

class FeedbackListPage extends StatefulWidget {
  const FeedbackListPage({super.key});

  @override
  State<FeedbackListPage> createState() => _FeedbackListPageState();
}

class _FeedbackListPageState extends State<FeedbackListPage> {
  List<FeedbackItem> _feedbackList = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFeedback();
  }

  Future<void> _loadFeedback() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final feedback = await FeedbackService.getAllFeedback(limit: 100);

    if (mounted) {
      setState(() {
        _feedbackList = feedback;
        _isLoading = false;
        if (feedback.isEmpty) {
          _error = 'No feedback found or access denied';
        }
      });
    }
  }

  IconData _getTypeIcon(FeedbackType type) {
    switch (type) {
      case FeedbackType.comment:
        return Icons.chat_bubble_outline;
      case FeedbackType.bug:
        return Icons.bug_report_outlined;
      case FeedbackType.suggestion:
        return Icons.lightbulb_outline;
    }
  }

  Color _getTypeColor(FeedbackType type) {
    switch (type) {
      case FeedbackType.comment:
        return Colors.blue;
      case FeedbackType.bug:
        return Colors.red;
      case FeedbackType.suggestion:
        return Colors.orange;
    }
  }

  String _getTypeLabel(FeedbackType type, AppLocalizations? l10n) {
    switch (type) {
      case FeedbackType.comment:
        return l10n?.feedbackTypeComment ?? 'Comment';
      case FeedbackType.bug:
        return l10n?.feedbackTypeBug ?? 'Bug';
      case FeedbackType.suggestion:
        return l10n?.feedbackTypeSuggestion ?? 'Suggestion';
    }
  }

  String _formatDate(DateTime date) {
    final locale = SharedPreferencesUtil().appLanguage;
    return DateFormat('MMM d, yyyy HH:mm', locale).format(date.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        title: Text(l10n?.feedbackReceived ?? 'Feedback Received'),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFeedback,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _feedbackList.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inbox_outlined, size: 64, color: Colors.grey.shade600),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: _loadFeedback,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadFeedback,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _feedbackList.length,
                    itemBuilder: (context, index) {
                      final item = _feedbackList[index];
                      return _buildFeedbackCard(item, l10n);
                    },
                  ),
                ),
    );
  }

  Widget _buildFeedbackCard(FeedbackItem item, AppLocalizations? l10n) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with type and date
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getTypeColor(item.feedbackType).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _getTypeIcon(item.feedbackType),
                        size: 14,
                        color: _getTypeColor(item.feedbackType),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _getTypeLabel(item.feedbackType, l10n),
                        style: TextStyle(
                          color: _getTypeColor(item.feedbackType),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  _formatDate(item.createdAt),
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Message
            Text(
              item.message,
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
            ),

            // Device info
            if (item.deviceInfo != null && item.deviceInfo!.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(color: Color(0xFF3C3C43), height: 1),
              const SizedBox(height: 8),
              Text(
                item.deviceInfo!,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
              ),
            ],

            // App version
            if (item.appVersion != null && item.appVersion!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'v${item.appVersion}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
