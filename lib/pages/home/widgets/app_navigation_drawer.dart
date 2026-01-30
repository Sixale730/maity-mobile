import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/memories/page.dart';
import 'package:omi/pages/settings/settings_drawer.dart';
import 'package:omi/pages/speech_profile/page.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:provider/provider.dart';

class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Drawer(
      backgroundColor: const Color(0xFF121215),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topRight: Radius.circular(20), bottomRight: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Consumer<HomeProvider>(
          builder: (context, home, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // App branding
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF485DF4).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Center(
                          child: Text('M', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF485DF4))),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text('Maity', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                    ],
                  ),
                ),

                Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),

                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      // Main section
                      _buildSectionHeader(l10n.drawerMain),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.house,
                        label: l10n.home,
                        isSelected: home.selectedIndex == 0,
                        onTap: () => _navigateToTab(context, 0),
                      ),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.solidMessage,
                        label: l10n.conversations,
                        isSelected: home.selectedIndex == 1,
                        onTap: () => _navigateToTab(context, 1),
                      ),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.listCheck,
                        label: l10n.toDos,
                        isSelected: home.selectedIndex == 3,
                        onTap: () => _navigateToTab(context, 3),
                      ),

                      const SizedBox(height: 8),
                      Divider(color: Colors.white.withValues(alpha: 0.06), height: 1, indent: 20, endIndent: 20),
                      const SizedBox(height: 8),

                      // Analysis section
                      _buildSectionHeader(l10n.drawerAnalysis),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.chartLine,
                        label: l10n.insights,
                        isSelected: home.selectedIndex == 4,
                        onTap: () => _navigateToTab(context, 4),
                      ),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.lightbulb,
                        label: l10n.memories,
                        onTap: () {
                          Navigator.pop(context); // Close drawer
                          MixpanelManager().track('Drawer Item Clicked', properties: {'item': 'Memories'});
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const MemoriesPage()),
                          );
                        },
                      ),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.chartColumn,
                        label: l10n.dailyReport,
                        onTap: () {
                          Navigator.pop(context);
                          MixpanelManager().track('Drawer Item Clicked', properties: {'item': 'Daily Report'});
                          // Navigate to Insights which shows the report
                          context.read<HomeProvider>().setIndex(4);
                        },
                      ),

                      const SizedBox(height: 8),
                      Divider(color: Colors.white.withValues(alpha: 0.06), height: 1, indent: 20, endIndent: 20),
                      const SizedBox(height: 8),

                      // Profile section
                      _buildSectionHeader(l10n.drawerProfile),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.gear,
                        label: l10n.configuration,
                        onTap: () {
                          Navigator.pop(context);
                          MixpanelManager().track('Drawer Item Clicked', properties: {'item': 'Settings'});
                          SettingsDrawer.show(context);
                        },
                      ),
                      _buildNavItem(
                        context,
                        icon: FontAwesomeIcons.microphoneLines,
                        label: l10n.voiceProfile,
                        onTap: () {
                          Navigator.pop(context);
                          MixpanelManager().track('Drawer Item Clicked', properties: {'item': 'Voice Profile'});
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const SpeechProfilePage()),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey.shade600, letterSpacing: 1.2),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    bool isSelected = false,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF485DF4).withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -1),
        leading: FaIcon(
          icon,
          size: 18,
          color: isSelected ? const Color(0xFF485DF4) : Colors.grey.shade400,
        ),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            color: isSelected ? Colors.white : Colors.grey.shade300,
          ),
        ),
        onTap: () {
          HapticFeedback.mediumImpact();
          onTap();
        },
      ),
    );
  }

  void _navigateToTab(BuildContext context, int navIndex) {
    Navigator.pop(context); // Close drawer
    MixpanelManager().track('Drawer Item Clicked', properties: {'item': 'Tab $navIndex'});
    context.read<HomeProvider>().setIndex(navIndex);
  }
}
