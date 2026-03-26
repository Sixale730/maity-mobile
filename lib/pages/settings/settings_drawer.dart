import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/core/app_shell.dart';
import 'package:omi/pages/persona/persona_provider.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/pages/settings/about.dart';
import 'package:omi/pages/settings/data_privacy_page.dart';
import 'package:omi/pages/settings/developer.dart';
import 'package:omi/pages/settings/profile.dart';
import 'package:omi/widgets/dialog.dart';
// Intercom disabled - causes build issues
// import 'package:intercom_flutter/intercom_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:omi/env/env.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/main.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/providers/role_provider.dart';
import 'package:omi/pages/settings/feedback_page.dart';
import 'package:omi/pages/settings/feedback_list_page.dart';
import 'package:omi/pages/settings/transcription_settings_page.dart';
import 'package:omi/pages/speech_profile/page.dart';
import 'device_settings.dart';
import '../conversations/sync_page.dart';

enum SettingsMode {
  no_device,
  omi,
}

class SettingsDrawer extends StatefulWidget {
  final SettingsMode mode;

  const SettingsDrawer({
    super.key,
    this.mode = SettingsMode.omi,
  });

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();

  static void show(BuildContext context, {SettingsMode mode = SettingsMode.omi}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SettingsDrawer(mode: mode),
    );
  }
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  String? version;
  String? buildVersion;
  String? shortDeviceInfo;

  @override
  void initState() {
    super.initState();
    _loadAppAndDeviceInfo();
  }

  Future<String> _getShortDeviceInfo() async {
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        return '${androidInfo.brand} ${androidInfo.model} — Android ${androidInfo.version.release}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        return '${iosInfo.name} — iOS ${iosInfo.systemVersion}';
      } else {
        return 'Unknown Device';
      }
    } catch (e) {
      return 'Unknown Device';
    }
  }

  Future<void> _loadAppAndDeviceInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final shortDevice = await _getShortDeviceInfo();

      if (mounted) {
        setState(() {
          version = packageInfo.version;
          buildVersion = packageInfo.buildNumber.toString();
          shortDeviceInfo = shortDevice;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          shortDeviceInfo = 'Unknown Device';
        });
      }
    }
  }

  Widget _buildSettingsItem({
    required String title,
    required Widget icon,
    required VoidCallback onTap,
    bool showBetaTag = false,
    bool showNewTag = false,
    Widget? trailingChip,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
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
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w400,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showBetaTag) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                          // border: Border.all(
                          //   color: Colors.orange,
                          //   width: 1,
                          // ),
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
                    if (showNewTag) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'NEW',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailingChip != null) ...[
                const SizedBox(width: 8),
                trailingChip,
                const SizedBox(width: 8),
              ],
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

  Widget _buildVersionInfoSection() {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    final displayText = buildVersion != null ? '${version ?? ""} ($buildVersion)' : (version ?? '');

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          displayText,
          style: const TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 13,
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(width: 2),
        GestureDetector(
          onTap: _copyVersionInfo,
          child: Container(
            padding: const EdgeInsets.all(2),
            child: const Icon(
              Icons.copy,
              size: 12,
              color: Color(0xFF8E8E93),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyVersionInfo() async {
    final versionPart = buildVersion != null ? 'Maity AI ${version ?? ""} ($buildVersion)' : 'Maity AI ${version ?? ""}';
    final devicePart = shortDeviceInfo ?? 'Unknown Device';
    final fullVersionInfo = '$versionPart — $devicePart';

    await Clipboard.setData(ClipboardData(text: fullVersionInfo));

    if (mounted) {
      _showCopyNotification();
    }
  }

  void _showLanguageSelector(BuildContext context) {
    final currentLanguage = SharedPreferencesUtil().appLanguage;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 4,
                width: 36,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF3C3C43),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                AppLocalizations.of(context)?.selectLanguage ?? 'Select Language',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Text('🇪🇸', style: TextStyle(fontSize: 24)),
                title: const Text('Español', style: TextStyle(color: Colors.white)),
                trailing: currentLanguage == 'es'
                    ? const Icon(Icons.check, color: Color(0xFFFF0050))
                    : null,
                onTap: () {
                  MyApp.changeLocale('es');
                  Navigator.pop(ctx); // Solo cerrar el modal de idioma
                },
              ),
              ListTile(
                leading: const Text('🇺🇸', style: TextStyle(fontSize: 24)),
                title: const Text('English', style: TextStyle(color: Colors.white)),
                trailing: currentLanguage == 'en'
                    ? const Icon(Icons.check, color: Color(0xFFFF0050))
                    : null,
                onTap: () {
                  MyApp.changeLocale('en');
                  Navigator.pop(ctx); // Solo cerrar el modal de idioma
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _getTranscriptionLanguageLabel() {
    final config = SharedPreferencesUtil().customSttConfig;
    if (!config.isEnabled) return 'Multi';
    final lang = config.language ?? 'multi';
    switch (lang) {
      case 'es':
        return 'Español';
      case 'en':
        return 'English';
      default:
        return 'Multi';
    }
  }

  void _showTranscriptionSettings(BuildContext context) {
    final roleProvider = context.read<RoleProvider>();

    // Admins get the full TranscriptionSettingsPage with model selection
    if (roleProvider.isAdmin) {
      _navigateAfterClose(context, const TranscriptionSettingsPage());
      return;
    }

    // Regular users get language selector + voice profile status
    final config = SharedPreferencesUtil().customSttConfig;
    final currentLang = config.isEnabled ? (config.language ?? 'multi') : 'multi';
    final hasVoiceProfile = SharedPreferencesUtil().hasSpeakerProfile;
    final hasLocalEmbedding = SharedPreferencesUtil().localSpeakerEmbeddingPath.isNotEmpty;
    final hasSpeakerModel = SharedPreferencesUtil().speakerModelDownloaded;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 4,
                width: 36,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF3C3C43),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text(
                'Transcripción',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    FaIcon(FontAwesomeIcons.boltLightning, color: Color(0xFF8E8E93), size: 16),
                    SizedBox(width: 8),
                    Text('Proveedor: ', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14)),
                    Text('Deepgram', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Idioma de transcripción',
                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _buildLanguageOption(ctx, 'Español', 'es', currentLang),
              _buildLanguageOption(ctx, 'English', 'en', currentLang),
              _buildLanguageOption(ctx, 'Auto-detect (Multi)', 'multi', currentLang),
              const SizedBox(height: 12),

              // Voice profile section
              const Divider(height: 1, color: Color(0xFF3C3C43)),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Perfil de voz',
                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              if (!hasVoiceProfile) ...[
                // No voice profile — show enroll button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        MyApp.navigatorKey.currentState?.push(
                          MaterialPageRoute(builder: (_) => const SpeechProfilePage()),
                        );
                      },
                      icon: const Icon(Icons.record_voice_over_rounded, size: 20),
                      label: const Text('Crear perfil de voz'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        elevation: 0,
                      ),
                    ),
                  ),
                ),
              ] else ...[
                // Has voice profile — show status checks
                _buildVoiceProfileStatus(
                  icon: Icons.check_circle,
                  color: Colors.green.shade400,
                  label: 'Cloud speaker verification',
                ),
                if (hasLocalEmbedding)
                  _buildVoiceProfileStatus(
                    icon: Icons.check_circle,
                    color: Colors.green.shade400,
                    label: 'On-device speaker ID',
                  )
                else if (hasSpeakerModel)
                  _buildVoiceProfileStatus(
                    icon: Icons.info_outline,
                    color: Colors.orange.shade400,
                    label: 'Re-enroll voice to enable on-device speaker ID',
                  )
                else
                  _buildVoiceProfileStatus(
                    icon: Icons.info_outline,
                    color: Colors.grey.shade500,
                    label: 'Download speaker model for on-device ID',
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceProfileStatus({
    required IconData icon,
    required Color color,
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageOption(BuildContext ctx, String label, String langCode, String currentLang) {
    final isSelected = currentLang == langCode;
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFFFF0050)) : null,
      onTap: () {
        final deepgramKey = Env.deepgramApiKey ?? '';
        final newConfig = CustomSttConfig(
          provider: SttProvider.deepgramLive,
          apiKey: deepgramKey,
          language: langCode,
        );
        SharedPreferencesUtil().saveCustomSttConfig(newConfig);
        SharedPreferencesUtil().userPrimaryLanguage = langCode;
        SharedPreferencesUtil().hasSetPrimaryLanguage = true;
        Navigator.pop(ctx);
        setState(() {});
      },
    );
  }

  /// Closes the settings drawer and navigates to a page.
  /// Uses the global navigator key since the modal bottom sheet's context
  /// becomes invalid after pop (unlike a Drawer, a modal is a separate route).
  void _navigateAfterClose(BuildContext context, Widget page) {
    Navigator.pop(context);
    MyApp.navigatorKey.currentState?.push(
      Platform.isIOS
          ? CupertinoPageRoute(builder: (_) => page)
          : MaterialPageRoute(builder: (_) => page),
    );
  }

  void _showCopyNotification() {
    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: 20,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.7,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Text(
                'App and device details copied',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);

    Future.delayed(const Duration(seconds: 2), () {
      overlayEntry.remove();
    });
  }

  Widget _buildOmiModeContent(BuildContext context) {
    final roleProvider = context.watch<RoleProvider>();

    return Column(
      children: [
          // Profile & Notifications Section
          _buildSectionContainer(
            children: [
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.profile ?? 'Profile',
                icon: const FaIcon(FontAwesomeIcons.solidUser, color: Color(0xFF8E8E93), size: 20),
                onTap: () => _navigateAfterClose(context, const ProfilePage()),
              ),
              // Storage - Admin only
              if (roleProvider.isAdmin) ...[
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildSettingsItem(
                  title: AppLocalizations.of(context)?.storage ?? 'Storage',
                  icon: const FaIcon(FontAwesomeIcons.database, color: Color(0xFF8E8E93), size: 20),
                  onTap: () => _navigateAfterClose(context, const SyncPage()),
                ),
              ],
              const Divider(height: 1, color: Color(0xFF3C3C43)),
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.deviceSettings ?? 'Device Settings',
                icon: const FaIcon(FontAwesomeIcons.bluetooth, color: Color(0xFF8E8E93), size: 20),
                onTap: () => _navigateAfterClose(context, const DeviceSettings()),
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Share Section
          _buildSectionContainer(
            children: [
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.shareMaity ?? 'Share Maity',
                icon: const FaIcon(FontAwesomeIcons.solidShareFromSquare, color: Color(0xFF8E8E93), size: 20),
                onTap: () async {
                  Navigator.pop(context);
                  await Share.share('https://maity.com.mx');
                },
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Feedback Section
          _buildSectionContainer(
            children: [
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.sendFeedback ?? 'Send Feedback',
                icon: const FaIcon(FontAwesomeIcons.solidEnvelope, color: Color(0xFF8E8E93), size: 20),
                onTap: () => _navigateAfterClose(context, const FeedbackPage()),
              ),
              // Feedback Received - Admin only
              if (roleProvider.isAdmin) ...[
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildSettingsItem(
                  title: AppLocalizations.of(context)?.feedbackReceived ?? 'Feedback Received',
                  icon: const FaIcon(FontAwesomeIcons.inbox, color: Color(0xFF8E8E93), size: 20),
                  onTap: () => _navigateAfterClose(context, const FeedbackListPage()),
                ),
              ],
            ],
          ),
          const SizedBox(height: 32),

          // Privacy & Settings Section
          _buildSectionContainer(
            children: [
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.dataPrivacy ?? 'Data & Privacy',
                icon: const FaIcon(FontAwesomeIcons.shield, color: Color(0xFF8E8E93), size: 20),
                onTap: () => _navigateAfterClose(context, const DataPrivacyPage()),
              ),
              const Divider(height: 1, color: Color(0xFF3C3C43)),
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.language ?? 'Language',
                icon: const FaIcon(FontAwesomeIcons.globe, color: Color(0xFF8E8E93), size: 20),
                trailingChip: Text(
                  SharedPreferencesUtil().appLanguage == 'es' ? 'Español' : 'English',
                  style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                ),
                onTap: () => _showLanguageSelector(context),
              ),
              const Divider(height: 1, color: Color(0xFF3C3C43)),
              _buildSettingsItem(
                title: 'Transcripción',
                icon: const FaIcon(FontAwesomeIcons.microphone, color: Color(0xFF8E8E93), size: 20),
                trailingChip: roleProvider.isAdmin
                    ? const Icon(Icons.chevron_right, color: Color(0xFF8E8E93), size: 20)
                    : Text(
                        _getTranscriptionLanguageLabel(),
                        style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                      ),
                onTap: () => _showTranscriptionSettings(context),
              ),
              // Developer Settings - Admin only
              if (roleProvider.isAdmin) ...[
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildSettingsItem(
                  title: AppLocalizations.of(context)?.developerSettings ?? 'Developer Settings',
                  icon: const FaIcon(FontAwesomeIcons.code, color: Color(0xFF8E8E93), size: 20),
                  onTap: () => _navigateAfterClose(context, const DeveloperSettingsPage()),
                ),
              ],
              const Divider(height: 1, color: Color(0xFF3C3C43)),
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.aboutMaity ?? 'About Maity',
                icon: const FaIcon(FontAwesomeIcons.infoCircle, color: Color(0xFF8E8E93), size: 20),
                onTap: () => _navigateAfterClose(context, const AboutOmiPage()),
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Sign Out Section
          _buildSectionContainer(
            children: [
              _buildSettingsItem(
                title: AppLocalizations.of(context)?.signOut ?? 'Sign Out',
                icon: const FaIcon(FontAwesomeIcons.signOutAlt, color: Color(0xFF8E8E93), size: 20),
                onTap: () async {
                  // Capture the provider reference before any navigation
                  final personaProvider = Provider.of<PersonaProvider>(context, listen: false);
                  final navigator = Navigator.of(context);
                  final signOutQuestion = AppLocalizations.of(context)?.signOutQuestion ?? 'Sign Out?';
                  final signOutConfirmation = AppLocalizations.of(context)?.signOutConfirmation ?? 'Are you sure you want to sign out?';

                  navigator.pop(); // Close the settings drawer

                  await showDialog(
                    context: context,
                    builder: (ctx) {
                      return getDialog(
                        ctx,
                        () => Navigator.of(ctx).pop(),
                        () async {
                          Navigator.of(ctx).pop();
                          // Preserve device/onboarding preferences before clearing
                          final onboardingCompleted = SharedPreferencesUtil().onboardingCompleted;
                          final hasSetPrimaryLanguage = SharedPreferencesUtil().hasSetPrimaryLanguage;
                          final userPrimaryLanguage = SharedPreferencesUtil().userPrimaryLanguage;
                          final appLanguage = SharedPreferencesUtil().appLanguage;

                          await SharedPreferencesUtil().clear();

                          // Restore device/onboarding preferences
                          SharedPreferencesUtil().onboardingCompleted = onboardingCompleted;
                          SharedPreferencesUtil().hasSetPrimaryLanguage = hasSetPrimaryLanguage;
                          SharedPreferencesUtil().userPrimaryLanguage = userPrimaryLanguage;
                          SharedPreferencesUtil().appLanguage = appLanguage;

                          await AuthService.instance.signOut();
                          personaProvider.setRouting(PersonaProfileRouting.no_device);
                          MyApp.navigatorKey.currentState?.pushAndRemoveUntil(
                            MaterialPageRoute(builder: (_) => const AppShell()),
                            (route) => false,
                          );
                        },
                        signOutQuestion,
                        signOutConfirmation,
                      );
                    },
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Version Info
          _buildVersionInfoSection(),
          const SizedBox(height: 24),
        ],
      );
  }

  Widget _buildNoDeviceModeContent(BuildContext context) {
    return Column(
      children: [
        // Support Section
        _buildSectionContainer(
          children: [
            _buildSettingsItem(
              title: AppLocalizations.of(context)?.needHelpChat ?? 'Need Help? Chat with us',
              icon: const FaIcon(FontAwesomeIcons.solidComments, color: Color(0xFF8E8E93), size: 20),
              onTap: () async {
                Navigator.pop(context);
                // Intercom disabled
                // await Intercom.instance.displayMessenger();
              },
            ),
          ],
        ),
        const SizedBox(height: 32),

        // Sign Out Section
        _buildSectionContainer(
          children: [
            _buildSettingsItem(
              title: AppLocalizations.of(context)?.signOut ?? 'Sign Out',
              icon: const FaIcon(FontAwesomeIcons.signOutAlt, color: Color(0xFF8E8E93), size: 20),
              onTap: () async {
                // Capture the provider reference before any navigation
                final personaProvider = Provider.of<PersonaProvider>(context, listen: false);
                final navigator = Navigator.of(context);
                final signOutQuestion = AppLocalizations.of(context)?.signOutQuestion ?? 'Sign Out?';
                final signOutConfirmation = AppLocalizations.of(context)?.signOutConfirmation ?? 'Are you sure you want to sign out?';

                navigator.pop(); // Close the settings drawer

                await showDialog(
                  context: context,
                  builder: (ctx) {
                    return getDialog(
                      ctx,
                      () => Navigator.of(ctx).pop(),
                      () async {
                        Navigator.of(ctx).pop(); // Close dialog first
                        SharedPreferencesUtil().hasOmiDevice = null;
                        SharedPreferencesUtil().verifiedPersonaId = null;
                        personaProvider.setRouting(PersonaProfileRouting.no_device);
                        await AuthService.instance.signOut();
                        MyApp.navigatorKey.currentState?.pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const AppShell()),
                          (route) => false,
                        );
                      },
                      signOutQuestion,
                      signOutConfirmation,
                    );
                  },
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 32),

        // Version Info
        _buildVersionInfoSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: const BoxDecoration(
        color: Color(0xFF000000),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 8),
            height: 4,
            width: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF3C3C43),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Stack(
              children: [
                // Centered title and email
                Center(
                  child: Column(
                    children: [
                      Text(
                        AppLocalizations.of(context)?.settings ?? 'Settings',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        SharedPreferencesUtil().email ?? '',
                        style: const TextStyle(
                          color: Color(0xFF8E8E93),
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                // Done button positioned to the right
                Positioned(
                  right: 0,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Text(
                      AppLocalizations.of(context)?.done ?? 'Done',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child:
                  widget.mode == SettingsMode.omi ? _buildOmiModeContent(context) : _buildNoDeviceModeContent(context),
            ),
          ),
        ],
      ),
    );
  }
}
