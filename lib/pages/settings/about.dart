import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/settings/privacy.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutOmiPage extends StatefulWidget {
  const AboutOmiPage({super.key});

  @override
  State<AboutOmiPage> createState() => _AboutOmiPageState();
}

class _AboutOmiPageState extends State<AboutOmiPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      appBar: AppBar(
        title: Text(l10n?.aboutMaityTitle ?? 'About Maity'),
        backgroundColor: Theme.of(context).colorScheme.primary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
              title: Text(l10n?.privacyPolicyTitle ?? 'Privacy Policy', style: const TextStyle(color: Colors.white)),
              trailing: const Icon(Icons.privacy_tip_outlined, size: 20),
              onTap: () {
                MixpanelManager().pageOpened('About Privacy Policy');
                routeToPage(context, const PrivacyInfoPage());
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
              title: Text(l10n?.visitWebsite ?? 'Visit Website', style: const TextStyle(color: Colors.white)),
              subtitle: const Text('https://maity.com.mx'),
              trailing: const Icon(Icons.language_outlined, size: 20),
              onTap: () {
                MixpanelManager().pageOpened('About Visit Website');
                launchUrl(Uri.parse('https://maity.com.mx/'));
              },
            ),
            ListTile(
              title: Text(l10n?.helpOrInquiries ?? 'Help or Inquiries?', style: const TextStyle(color: Colors.white)),
              subtitle: const Text('julio.gonzalez@maity.com.mx'),
              contentPadding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
              trailing: const Icon(Icons.help_outline_outlined, color: Colors.white, size: 20),
              onTap: () async {
                final Uri emailUri = Uri(
                  scheme: 'mailto',
                  path: 'julio.gonzalez@maity.com.mx',
                  queryParameters: {'subject': 'Maity App - Help Request'},
                );
                if (await canLaunchUrl(emailUri)) {
                  await launchUrl(emailUri);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
