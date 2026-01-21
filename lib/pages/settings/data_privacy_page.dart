import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/settings/widgets/data_protection_section.dart';
import 'package:omi/providers/user_provider.dart';
import 'package:provider/provider.dart';

class DataPrivacyPage extends StatefulWidget {
  const DataPrivacyPage({super.key});

  @override
  State<DataPrivacyPage> createState() => _DataPrivacyPageState();
}

class _DataPrivacyPageState extends State<DataPrivacyPage> {
  @override
  void initState() {
    super.initState();
  }

  Widget _buildIntroSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Text(
            '🛡️',
            style: TextStyle(fontSize: 64),
          ),
          const SizedBox(height: 16),
          Text(
            l10n?.yourPrivacyYourControl ?? 'Your Privacy, Your Control',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              l10n?.atMaityPrivacyCommitment ??
                  'At Maity, we are committed to protecting your privacy. This page allows you to control how your data is stored and used.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey.shade400, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Consumer<UserProvider>(
      builder: (context, provider, child) {
        final isLoading = provider.isLoading;
        final isMigrating = provider.isMigrating;

        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.primary,
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            automaticallyImplyLeading: true,
            title: Text(
              l10n?.dataPrivacyTitle ?? 'Data & Privacy',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            centerTitle: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new),
              onPressed: () => Navigator.pop(context),
            ),
            elevation: 0,
          ),
          body: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  _buildIntroSection(context),
                  const SizedBox(height: 32),
                  Text(
                    l10n?.dataProtectionLevel ?? 'Data Protection Level',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n?.dataProtectionDescription ??
                        'Your data is secured by default with strong encryption. Review your settings and future privacy options below.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  const DataProtectionSection(),
                  const SizedBox(height: 32),
                ],
              ),
              if (isLoading && !isMigrating)
                Container(
                  color: Colors.black.withValues(alpha: 0.5),
                  child: const Center(
                    child: CircularProgressIndicator(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
