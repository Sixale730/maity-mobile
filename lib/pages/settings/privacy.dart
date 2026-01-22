import 'package:flutter/material.dart';
import 'package:omi/l10n/app_localizations.dart';

class PrivacyInfoPage extends StatelessWidget {
  const PrivacyInfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      appBar: AppBar(
        title: Text(l10n?.privacyInformationTitle ?? 'Privacy Information'),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            Text(
              l10n?.yourPrivacyMatters ?? 'Your Privacy Matters to Us',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n?.privacyIntro ??
                  'At Maity, we take your privacy very seriously. We want to be transparent about the data we collect and how we use it to improve our product for you. Here\'s what you need to know:',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            Text(
              l10n?.whatWeTrack ?? 'What We Track',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildBulletPoint(
                'Onboarding Events: We track when you connect your device and complete the onboarding process.'),
            _buildBulletPoint(
                'Settings Interactions: We track when you open and save settings, and when you enable or disable developer mode.'),
            _buildBulletPoint('Apps Interactions: We track when you open apps, and when you enable or disable them.'),
            _buildBulletPoint('Device Status: We track when your device connects or disconnects.'),
            _buildBulletPoint('Language Changes: We track changes to your recording language.'),
            _buildBulletPoint('Navigation: We track clicks on different tabs in the bottom navigation.'),
            _buildBulletPoint(
                'Transcript and Conversation Data: We track the length, word count, and number of speakers in your transcripts. For memories, we track their creation, editing, sharing, and deletion.'),
            _buildBulletPoint('Feedback: We track feedback given to the Coach Advisor.'),
            _buildBulletPoint('Chat Interactions: We track messages sent and interactions with memories through chat.'),
            _buildBulletPoint(
                'Speech Profile: We track the capture, start, onboarding, and completion of your speech profile.'),
            _buildBulletPoint(
                'Show Discarded Conversations: We track when you toggle the option to show discarded conversations.'),
            _buildBulletPoint('Manual Memories: We track when you add or create manual memories.'),
            _buildBulletPoint(
                'User Properties: We track user properties such as occupation, usage location, and age range.'),
            _buildBulletPoint('Conversation Re-processing: We track when you re-process a conversation.'),
            _buildBulletPoint(
                'Backups: We track when backups are enabled or disabled, and when a backups password is set.'),
            _buildBulletPoint('Support: We track when you contact support.'),
            _buildBulletPoint('Privacy Page: We track when you open the privacy details page.'),
            _buildBulletPoint('Copy Conversation Details: We track when you copy conversation details.'),
            _buildBulletPoint('Get/Connect Device: We track when you click to get or connect your device.'),
            _buildBulletPoint('Disconnect Device: We track when you disconnect your device.'),
            _buildBulletPoint('Battery Indicator: We track when you click the battery indicator.'),
            const SizedBox(height: 16),
            Text(
              l10n?.anonymityAndPrivacy ?? 'Anonymity and Privacy',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildBulletPoint(
                'Anonymous Tracking: All tracking is 100% anonymous. We do not collect or store any personal information like your email address.'),
            _buildBulletPoint(
                'Randomly Generated IDs: Each user is assigned a randomly generated ID, ensuring that nothing can be personally associated with you.'),
            _buildBulletPoint(
                'No Selling of Data: We do not sell or share your data with any third parties. The data we collect is solely used to understand how you use the app and to make improvements.'),
            const SizedBox(height: 16),
            Text(
              l10n?.optInOutOptions ?? 'Opt-In and Opt-Out Options',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildBulletPoint('Opt-In: You can choose to opt in to tracking to help us enhance your experience.'),
            _buildBulletPoint('Opt-Out: You can opt out of tracking at any time, and we will reset all your data.'),
            const SizedBox(height: 16),
            Text(
              l10n?.ourCommitment ?? 'Our Commitment',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n?.privacyCommitmentText ??
                  'We are committed to using the data we collect only to make Maity a better product for you. Your privacy and trust are paramount to us.',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            Text(
              l10n?.privacyThankYou ??
                  'Thank you for being a valued user of Maity. If you have any questions or concerns, feel free to reach out to us at julio.gonzalez@maity.com.mx.',
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBulletPoint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontSize: 16)),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}
