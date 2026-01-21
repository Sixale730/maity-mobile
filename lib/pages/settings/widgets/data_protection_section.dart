import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/user_provider.dart';
import 'package:provider/provider.dart';

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) {
      return this;
    }
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}

class DataProtectionSection extends StatefulWidget {
  const DataProtectionSection({super.key});

  @override
  State<DataProtectionSection> createState() => _DataProtectionSectionState();
}

class _DataProtectionSectionState extends State<DataProtectionSection> {
  @override
  void initState() {
    super.initState();
  }

  void _showE2eeComingSoonDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2c2c2e),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            const Icon(Icons.lock_person_outlined, color: Colors.white),
            const SizedBox(width: 10),
            Text(l10n?.maximumSecurityE2ee ?? 'Maximum Security (E2EE)',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: RichText(
          text: TextSpan(
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8), height: 1.5, fontSize: 15),
            children: [
              TextSpan(text: '${l10n?.e2eeDialogContent ?? "End-to-end encryption is the gold standard for privacy. When enabled, your data is encrypted on your device before it's sent to our servers. This means no one, not even Maity, can access your content."}\n\n'),
              TextSpan(
                text: '${l10n?.importantTradeoffs ?? "Important Trade-offs:"}\n',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              TextSpan(text: '• ${l10n?.e2eeTradeoff1 ?? "Some features like external app integrations may be disabled."}\n'),
              TextSpan(text: '• ${l10n?.e2eeTradeoff2 ?? "If you lose your password, your data cannot be recovered."}\n\n'),
              TextSpan(
                text: l10n?.featureComingSoon ?? 'This feature is coming soon!',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n?.ok ?? 'OK', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
        final isMigrating = provider.isMigrating;
        final migrationFailed = provider.migrationFailed;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isMigrating || migrationFailed) _buildMigrationStatus(context, provider),
            if (isMigrating)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(bottom: 16, left: 8, right: 8),
                child: Text(
                  l10n?.migrationInProgress ??
                      'Migration in progress. You cannot change the protection level until it is complete.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.9),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            _buildDefaultProtectionCard(context),
            _buildE2eeCard(context),
            const SizedBox(height: 12),
            _buildInfoRow(
              Icons.shield_outlined,
              l10n?.dataAlwaysEncrypted ??
                  'Regardless of the level, your data is always encrypted at rest and in transit.',
            ),
          ],
        );
      },
    );
  }

  Widget _buildMigrationStatus(BuildContext context, UserProvider provider) {
    final l10n = AppLocalizations.of(context);
    if (provider.migrationFailed) {
      return Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 24),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.shade300),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, color: Colors.red.shade300, size: 20),
                const SizedBox(width: 8),
                Text(
                  l10n?.migrationFailed ?? 'Migration Failed',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              provider.migrationMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade300, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                provider.updateDataProtectionLevel(provider.targetLevel);
              },
              icon: const Icon(Icons.refresh),
              label: Text(l10n?.retry ?? 'Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                foregroundColor: Colors.white,
              ),
            )
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF35343B).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepPurple.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.4),
              children: [
                TextSpan(text: '${l10n?.migratingFrom ?? "Migrating from"} '),
                TextSpan(
                  text: provider.sourceLevel.capitalize(),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: ' ${l10n?.migratingTo ?? "to"} '),
                TextSpan(
                  text: provider.targetLevel.capitalize(),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: provider.migrationTotalCount > 0
                      ? provider.migrationProcessedCount / provider.migrationTotalCount
                      : 0.0,
                  backgroundColor: Colors.grey.shade700,
                  color: Colors.deepPurple,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                provider.migrationTotalCount > 0
                    ? '${(provider.migrationProcessedCount / provider.migrationTotalCount * 100).toInt()}%'
                    : '0%',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                provider.migrationETA,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              Text(
                '${provider.migrationProcessedCount} / ${provider.migrationTotalCount} ${l10n?.objects ?? "objects"}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultProtectionCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.secondary,
          width: 1.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.verified_user_outlined,
            color: Theme.of(context).colorScheme.secondary,
            size: 28,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n?.secureEncryption ?? 'Secure Encryption',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n?.secureEncryptionDesc ??
                      'Your data is encrypted with a key unique to you on our servers, hosted on Google Cloud. This means your raw content is inaccessible to anyone, including Maity staff or Google, directly from the database.',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildE2eeCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: () => _showE2eeComingSoonDialog(context),
      child: Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF35343B)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, color: Colors.grey.shade400, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          l10n?.endToEndEncryption ?? 'End-to-End Encryption',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade700,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          l10n?.comingSoon ?? 'Coming Soon',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n?.e2eeShortDesc ??
                        'Enable for maximum security where only you can access your data. Tap to learn more.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.4),
                  ),
                ],
              ),
            ),
            Icon(Icons.info_outline, color: Colors.grey.shade600, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.grey, size: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.grey, fontSize: 14, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
