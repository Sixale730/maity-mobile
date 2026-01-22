import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/home/page.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/onboarding_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'found_devices.dart';

class FindDevicesPage extends StatefulWidget {
  final bool isFromOnboarding;
  final VoidCallback goNext;
  final VoidCallback? onSkip;
  final bool includeSkip;

  const FindDevicesPage(
      {super.key, required this.goNext, this.includeSkip = true, this.isFromOnboarding = false, this.onSkip});

  @override
  State<FindDevicesPage> createState() => _FindDevicesPageState();
}

class _FindDevicesPageState extends State<FindDevicesPage> {
  OnboardingProvider? _provider;

  @override
  void initState() {
    super.initState();
    _provider = Provider.of<OnboardingProvider>(context, listen: false);

    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (widget.isFromOnboarding) {
        context.read<HomeProvider>().setupHasSpeakerProfile();
      }
      _scanDevices();
    });
  }

  @override
  dispose() {
    _provider = null;

    super.dispose();
  }

  Future<void> _scanDevices() async {
    _provider?.scanDevices(
      onShowDialog: () {
        if (mounted) {
          showDialog(
            context: context,
            builder: (c) => getDialog(
              context,
              () {
                Navigator.of(context).pop();
              },
              () {},
              'Enable Bluetooth',
              'Maity needs Bluetooth to connect to your wearable. Please enable Bluetooth and try again.',
              singleButton: true,
            ),
          );
        }
      },
    );
  }

  void _onUsePhoneMicrophone() {
    // Mark onboarding as complete and navigate to home
    SharedPreferencesUtil().onboardingCompleted = true;
    MixpanelManager().usePhoneMicrophoneOnboarding();
    routeToPage(context, const HomePageWrapper(), replace: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Consumer<OnboardingProvider>(
      builder: (context, provider, child) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            FoundDevices(
              goNext: widget.goNext,
              isFromOnboarding: widget.isFromOnboarding,
            ),
            if (provider.deviceList.isEmpty && provider.enableInstructions) const SizedBox(height: 48),
            if (provider.deviceList.isEmpty && provider.enableInstructions)
              ElevatedButton(
                onPressed: () => launchUrl(Uri.parse('mailto:julio.gonzalez@maity.com.mx')),
                child: Container(
                  width: double.infinity,
                  height: 45,
                  alignment: Alignment.center,
                  child: Text(
                    l10n?.contactSupport ?? 'Contact Support?',
                    style: const TextStyle(
                      fontWeight: FontWeight.w400,
                      fontSize: 16,
                      color: Colors.white,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),

            // Divider "o" / "or"
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Row(
                children: [
                  Expanded(child: Divider(color: Colors.grey.shade700, thickness: 1)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      l10n?.orDivider ?? 'or',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                    ),
                  ),
                  Expanded(child: Divider(color: Colors.grey.shade700, thickness: 1)),
                ],
              ),
            ),

            // Use Phone Microphone Card
            GestureDetector(
              onTap: _onUsePhoneMicrophone,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade600),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.mic, size: 32, color: Colors.white),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n?.usePhoneMicrophone ?? 'Use Phone Microphone',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n?.usePhoneMicrophoneDesc ?? 'Record with your device\'s built-in microphone',
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: Colors.grey.shade400),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            if (widget.includeSkip)
              ElevatedButton(
                onPressed: () {
                  if (widget.isFromOnboarding) {
                    widget.onSkip!();
                  } else {
                    widget.goNext();
                  }
                  MixpanelManager().useWithoutDeviceOnboardingFindDevices();
                },
                child: Container(
                  width: double.infinity,
                  height: 45,
                  alignment: Alignment.center,
                  child: Text(
                    l10n?.connectLater ?? 'Connect Later',
                    style: const TextStyle(
                      fontWeight: FontWeight.w400,
                      fontSize: 16,
                      color: Colors.white,
                      // decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
