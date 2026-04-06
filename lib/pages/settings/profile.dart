import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/pages/settings/change_name_widget.dart';
import 'package:omi/pages/settings/conversation_timeout_dialog.dart';
import 'package:omi/pages/settings/language_selection_dialog.dart';
import 'package:omi/pages/settings/people.dart';
import 'package:omi/pages/settings/privacy.dart';
import 'package:omi/pages/settings/import_history_page.dart';
import 'package:omi/pages/speech_profile/page.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:provider/provider.dart';
import 'delete_account.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  @override
  void initState() {
    super.initState();
  }

  Widget _buildSectionContainer({required List<Widget> children}) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _buildProfileItem({
    required String title,
    String? subtitle,
    required Widget icon,
    required VoidCallback onTap,
    bool showSubtitle = true,
    bool showBetaTag = false,
    bool showTrainedTag = false,
    String? trainedLabel,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: icon,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        if (showBetaTag) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              'BETA',
                              style: TextStyle(
                                color: Colors.orange,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                        if (showTrainedTag) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 12,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  trainedLabel ?? 'Trained',
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (showSubtitle && subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFF8E8E93),
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFF3C3C43),
                size: 20,
              ),
            ],
          ),
      ),
    );
  }

  Widget _buildPreferenceToggle({
    required String title,
    required bool value,
    required Function(bool) onChanged,
    required VoidCallback onInfoTap,
  }) {
    return _buildSectionContainer(
      children: [
        Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: FaIcon(FontAwesomeIcons.chartLine, color: Color(0xFF8E8E93), size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: GestureDetector(
                onTap: onInfoTap,
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            GestureDetector(
              onTap: () => onChanged(!value),
              child: Container(
                decoration: BoxDecoration(
                  color: value ? const Color(0xFF007AFF) : Colors.transparent,
                  border: Border.all(
                    color: value ? const Color(0xFF007AFF) : const Color(0xFF8E8E93),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                width: 24,
                height: 24,
                child: value
                    ? const Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 16,
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        title: Text(
          AppLocalizations.of(context)?.profile ?? 'Profile',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF000000),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          children: <Widget>[
            const SizedBox(height: 20),

            // DEBUG: Supabase Login Status (developer-only)
            if (SharedPreferencesUtil().email.endsWith('@asertio.mx'))
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: SupabaseAuthService.instance.isSignedIn
                    ? Colors.green.withValues(alpha: 0.2)
                    : Colors.red.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: SupabaseAuthService.instance.isSignedIn
                      ? Colors.green
                      : Colors.red,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    SupabaseAuthService.instance.isSignedIn
                        ? Icons.check_circle
                        : Icons.error,
                    color: SupabaseAuthService.instance.isSignedIn
                        ? Colors.green
                        : Colors.red,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          SupabaseAuthService.instance.isSignedIn
                              ? 'Supabase Login OK'
                              : 'No Supabase User',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        if (SupabaseAuthService.instance.isSignedIn)
                          Text(
                            'UID: ${SupabaseAuthService.instance.authId}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // YOUR INFORMATION SECTION
            _buildSectionContainer(
              children: [
                _buildProfileItem(
                  title: SharedPreferencesUtil().givenName.isEmpty
                      ? (AppLocalizations.of(context)?.setYourName ?? 'Set Your Name')
                      : (AppLocalizations.of(context)?.changeYourName ?? 'Change Your Name'),
                  icon: const FaIcon(FontAwesomeIcons.solidUser, color: Color(0xFF8E8E93), size: 20),
                  onTap: () async {
                    MixpanelManager().pageOpened('Profile Change Name');
                    await showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return const ChangeNameWidget();
                      },
                    ).whenComplete(() => setState(() {}));
                  },
                ),
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                Consumer<HomeProvider>(
                  builder: (context, homeProvider, _) {
                    final matchingEntries = homeProvider.userPrimaryLanguage.isNotEmpty
                        ? homeProvider.availableLanguages.entries
                            .where((element) => element.value == homeProvider.userPrimaryLanguage)
                            .toList()
                        : <MapEntry<String, String>>[];
                    final languageName = matchingEntries.isNotEmpty
                        ? matchingEntries.first.key
                        : 'Not set';

                    return _buildProfileItem(
                      title: AppLocalizations.of(context)?.primaryLanguage ?? 'Primary Language',
                      subtitle: languageName,
                      icon: const FaIcon(FontAwesomeIcons.globe, color: Color(0xFF8E8E93), size: 20),
                      onTap: () async {
                        MixpanelManager().pageOpened('Profile Change Language');
                        await LanguageSelectionDialog.show(context, isRequired: false, forceShow: true);
                        await homeProvider.setupUserPrimaryLanguage();
                        setState(() {});
                      },
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),

            // VOICE & PEOPLE SECTION
            _buildSectionContainer(
              children: [
                _buildProfileItem(
                  title: AppLocalizations.of(context)?.speechProfile ?? 'Speech Profile',
                  icon: const FaIcon(FontAwesomeIcons.microphone, color: Color(0xFF8E8E93), size: 20),
                  showTrainedTag: SharedPreferencesUtil().hasSpeakerProfile,
                  trainedLabel: AppLocalizations.of(context)?.voiceProfileTrained ?? 'Trained',
                  onTap: () {
                    routeToPage(context, const SpeechProfilePage());
                    MixpanelManager().pageOpened('Profile Speech Profile');
                  },
                ),
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildProfileItem(
                  title: AppLocalizations.of(context)?.identifyingOthers ?? 'Identifying Others',
                  icon: const FaIcon(FontAwesomeIcons.users, color: Color(0xFF8E8E93), size: 20),
                  onTap: () {
                    routeToPage(context, const UserPeoplePage());
                  },
                ),
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildProfileItem(
                  title: AppLocalizations.of(context)?.conversationTimeout ?? 'Conversation Timeout',
                  icon: const FaIcon(FontAwesomeIcons.clock, color: Color(0xFF8E8E93), size: 20),
                  onTap: () {
                    ConversationTimeoutDialog.show(context);
                  },
                ),
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildProfileItem(
                  title: AppLocalizations.of(context)?.importData ?? 'Import Data',
                  icon: const FaIcon(FontAwesomeIcons.fileImport, color: Color(0xFF8E8E93), size: 20),
                  onTap: () {
                    routeToPage(context, const ImportHistoryPage());
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),

            // PREFERENCES SECTION
            _buildPreferenceToggle(
              title: AppLocalizations.of(context)?.helpImproveApp ?? 'Help improve Maity by sharing anonymized analytics data',
              value: SharedPreferencesUtil().optInAnalytics,
              onChanged: (value) {
                setState(() {
                  SharedPreferencesUtil().optInAnalytics = value;
                  value ? MixpanelManager().optInTracking() : MixpanelManager().optOutTracking();
                });
              },
              onInfoTap: () {
                routeToPage(context, const PrivacyInfoPage());
                MixpanelManager().pageOpened('Share Analytics Data Details');
              },
            ),
            const SizedBox(height: 32),

            // ACCOUNT SECTION
            _buildSectionContainer(
              children: [
                _buildProfileItem(
                  title: AppLocalizations.of(context)?.userId ?? 'User ID',
                  subtitle: SharedPreferencesUtil().uid,
                  icon: const FaIcon(FontAwesomeIcons.solidClipboard, color: Color(0xFF8E8E93), size: 20),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: SharedPreferencesUtil().uid));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)?.userIdCopied ?? 'User ID copied to clipboard')));
                  },
                ),
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildProfileItem(
                  title: AppLocalizations.of(context)?.deleteAccount ?? 'Delete Account',
                  subtitle: AppLocalizations.of(context)?.deleteAccountDesc ?? 'Delete your account and all data',
                  icon: const FaIcon(FontAwesomeIcons.exclamationTriangle, color: Colors.red, size: 20),
                  onTap: () {
                    MixpanelManager().pageOpened('Profile Delete Account Dialog');
                    Navigator.push(context, MaterialPageRoute(builder: (context) => const DeleteAccount()));
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
