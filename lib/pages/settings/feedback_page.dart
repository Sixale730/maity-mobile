import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/feedback_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _messageController = TextEditingController();
  FeedbackType _selectedType = FeedbackType.comment;
  bool _isSubmitting = false;
  String? _appVersion;
  String? _deviceInfo;

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final deviceInfoPlugin = DeviceInfoPlugin();

      String deviceDetails;
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        deviceDetails = '${androidInfo.brand} ${androidInfo.model} — Android ${androidInfo.version.release}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        deviceDetails = '${iosInfo.name} — iOS ${iosInfo.systemVersion}';
      } else {
        deviceDetails = 'Unknown Device';
      }

      if (mounted) {
        setState(() {
          _appVersion = '${packageInfo.version} (${packageInfo.buildNumber})';
          _deviceInfo = deviceDetails;
        });
      }
    } catch (e) {
      debugPrint('[FeedbackPage] Error loading device info: $e');
    }
  }

  Future<void> _submitFeedback() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) return;

    setState(() => _isSubmitting = true);

    final l10n = AppLocalizations.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final result = await FeedbackService.submitFeedback(
      type: _selectedType,
      message: message,
      appVersion: _appVersion,
      deviceInfo: _deviceInfo,
    );

    if (!mounted) return;

    setState(() => _isSubmitting = false);

    if (result != null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n?.feedbackSuccess ?? 'Thank you for your feedback!'),
          backgroundColor: Colors.green,
        ),
      );
      navigator.pop();
    } else {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(l10n?.feedbackError ?? 'Failed to submit. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _getTypeLabel(FeedbackType type, AppLocalizations? l10n) {
    switch (type) {
      case FeedbackType.comment:
        return l10n?.feedbackTypeComment ?? 'Comment';
      case FeedbackType.bug:
        return l10n?.feedbackTypeBug ?? 'Bug Report';
      case FeedbackType.suggestion:
        return l10n?.feedbackTypeSuggestion ?? 'Suggestion';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        title: Text(l10n?.sendFeedback ?? 'Send Feedback'),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Type selector
            Text(
              l10n?.feedbackType ?? 'Type',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<FeedbackType>(
                  value: _selectedType,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF1C1C1E),
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                  items: FeedbackType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Row(
                        children: [
                          Icon(
                            type == FeedbackType.comment
                                ? Icons.chat_bubble_outline
                                : type == FeedbackType.bug
                                    ? Icons.bug_report_outlined
                                    : Icons.lightbulb_outline,
                            color: type == FeedbackType.comment
                                ? Colors.blue
                                : type == FeedbackType.bug
                                    ? Colors.red
                                    : Colors.orange,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Text(_getTypeLabel(type, l10n)),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedType = value);
                    }
                  },
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Message field
            Text(
              l10n?.feedbackMessage ?? 'Your Message',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _messageController,
                maxLines: 8,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: l10n?.feedbackMessageHint ?? 'Tell us what you think...',
                  hintStyle: TextStyle(color: Colors.grey.shade600),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Device info display
            if (_appVersion != null || _deviceInfo != null) ...[
              Text(
                'App: ${_appVersion ?? "Unknown"}',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              if (_deviceInfo != null)
                Text(
                  'Device: $_deviceInfo',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              const SizedBox(height: 24),
            ],

            // Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSubmitting || _messageController.text.trim().isEmpty ? null : _submitFeedback,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF0050),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  disabledBackgroundColor: Colors.grey.shade700,
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        l10n?.feedbackSubmit ?? 'Submit',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
