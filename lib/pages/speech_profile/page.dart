import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/home/page.dart';
import 'package:omi/pages/settings/language_selection_dialog.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/speech_profile_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/analytics/intercom.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/widgets/device_widget.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:gradient_borders/box_borders/gradient_box_border.dart';
import 'package:provider/provider.dart';

import 'percentage_bar_progress.dart';

class SpeechProfilePage extends StatefulWidget {
  final bool onbording;

  const SpeechProfilePage({super.key, this.onbording = false});

  @override
  State<SpeechProfilePage> createState() => _SpeechProfilePageState();
}

class _SpeechProfilePageState extends State<SpeechProfilePage> with TickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final speechProvider = context.read<SpeechProfileProvider>();
      final homeProvider = context.read<HomeProvider>();

      speechProvider.close();
      await speechProvider.updateDevice();

      if (!mounted) return;

      if (!homeProvider.hasSetPrimaryLanguage) {
        await LanguageSelectionDialog.show(context);
      }
    });
  }

  // TODO: use connection directly
  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return BleAudioCodec.pcm8;
    }
    return connection.getAudioCodec();
  }

  @override
  void dispose() {
    // if (mounted) {
    //   context.read<SpeechProfileProvider>().dispose();
    // }
    super.dispose();
  }

  final ScrollController _scrollController = ScrollController();

  void scrollDown() async {
    if (_scrollController.hasClients) {
      await Future.delayed(const Duration(milliseconds: 250));
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _startWithBleDevice(
    SpeechProfileProvider provider,
    Future Function() stopDeviceRecording,
    Future Function() restartDeviceRecording,
  ) async {
    if (!context.read<HomeProvider>().hasSetPrimaryLanguage) {
      await LanguageSelectionDialog.show(context);
    }

    BleAudioCodec codec;
    try {
      codec = await _getAudioCodec(provider.device!.id);
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (c) => getDialog(
          context,
          () {
            Navigator.of(context).pop();
            Navigator.of(context).pop();
          },
          () => {},
          l10n?.deviceDisconnected ?? 'Device Disconnected',
          l10n?.deviceDisconnectedDesc ?? 'Please make sure your device is turned on and nearby, and try again.',
          singleButton: true,
        ),
      );
      return;
    }

    if (!codec.isOpusSupported()) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showDialog(
        context: context,
        builder: (c) => getDialog(
          context,
          () => Navigator.pop(context),
          () async {
            await IntercomManager.instance.displayFirmwareUpdateArticle();
          },
          l10n?.deviceUpdateRequired ?? 'Device Update Required',
          l10n?.deviceUpdateRequiredDesc ?? 'Your current device has an old firmware version (1.0.2). Please check our guide on how to update it.',
          okButtonText: l10n?.viewGuide ?? 'View Guide',
        ),
        barrierDismissible: false,
      );
      return;
    }

    await stopDeviceRecording();
    if (!mounted) return;
    Provider.of<CaptureProvider>(context, listen: false).enterSpeechProfileMode();
    try {
      await provider.initialise(finalizedCallback: restartDeviceRecording);
    } catch (e) {
      debugPrint('Speech profile initialise error: $e');
      if (context.mounted) {
        final l10n = AppLocalizations.of(context);
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (c) => getDialog(
            context,
            () {
              Navigator.of(context).pop();
            },
            () => {},
            l10n?.connectionError ?? 'Connection Error',
            '${l10n?.connectionErrorDesc ?? 'Failed to start speech profile recording. Please check your internet connection and try again.'}\n\nError: ${e.toString().replaceAll('Exception:', '').trim()}',
            singleButton: true,
          ),
        );
        await restartDeviceRecording();
      }
      return;
    }
    provider.forceCompletionTimer = Timer(Duration(seconds: provider.maxDuration), () {
      provider.finalize();
    });
    provider.updateStartedRecording(true);
  }

  Future<void> _startWithPhoneMic(
    SpeechProfileProvider provider,
    Future Function() stopDeviceRecording,
    Future Function() restartDeviceRecording,
  ) async {
    if (!context.read<HomeProvider>().hasSetPrimaryLanguage) {
      await LanguageSelectionDialog.show(context);
    }

    await stopDeviceRecording();
    if (!mounted) return;

    // Stop any active phone mic recording from CaptureProvider
    final captureProvider = Provider.of<CaptureProvider>(context, listen: false);
    captureProvider.enterSpeechProfileMode();

    try {
      await provider.initialise(finalizedCallback: restartDeviceRecording, usePhoneMic: true);
    } catch (e) {
      debugPrint('Speech profile phone mic initialise error: $e');
      if (context.mounted) {
        final l10n = AppLocalizations.of(context);
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (c) => getDialog(
            context,
            () {
              Navigator.of(context).pop();
            },
            () => {},
            l10n?.connectionError ?? 'Connection Error',
            '${l10n?.connectionErrorDesc ?? 'Failed to start speech profile recording. Please check your internet connection and try again.'}\n\nError: ${e.toString().replaceAll('Exception:', '').trim()}',
            singleButton: true,
          ),
        );
        await restartDeviceRecording();
      }
      return;
    }
    provider.forceCompletionTimer = Timer(Duration(seconds: provider.maxDuration), () {
      provider.finalize();
    });
    provider.updateStartedRecording(true);
  }

  @override
  Widget build(BuildContext context) {
    Future restartDeviceRecording() async {
      debugPrint("restartDeviceRecording $mounted");
      if (mounted) {
        final captureProvider = Provider.of<CaptureProvider>(context, listen: false);
        // Exit speech profile mode and clear any accumulated segments
        captureProvider.exitSpeechProfileMode();
        captureProvider.clearTranscripts();
        captureProvider.streamDeviceRecording(
          device: Provider.of<SpeechProfileProvider>(context, listen: false).deviceProvider?.connectedDevice,
        );
      }
    }

    Future stopDeviceRecording() async {
      debugPrint("stopDeviceRecording $mounted");
      if (mounted) {
        await Provider.of<CaptureProvider>(context, listen: false).stopStreamDeviceRecording();
      }
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          if (context.read<SpeechProfileProvider>().isInitialised) {
            final speechProvider = context.read<SpeechProfileProvider>();
            final captureProvider = context.read<CaptureProvider>();
            final device = speechProvider.deviceProvider?.connectedDevice;

            WidgetsBinding.instance.addPostFrameCallback((_) async {
              await speechProvider.close();

              captureProvider.clearTranscripts();
              captureProvider.streamDeviceRecording(device: device);
            });
          }
        }
      },
      child: Consumer2<SpeechProfileProvider, CaptureProvider>(builder: (context, provider, _, child) {
        return MessageListener<SpeechProfileProvider>(
          showInfo: (info) {
            if (info == 'SCROLL_DOWN') {
              scrollDown();
            }
          },
          showError: (error) {
            final l10n = AppLocalizations.of(context);
            if (error == 'MULTIPLE_SPEAKERS') {
              showDialog(
                context: context,
                builder: (c) => getDialog(
                  context,
                  () {
                    provider.resetSegments();
                    Navigator.pop(context);
                  },
                  () {},
                  l10n?.multipleSpeakersDetected ?? 'Multiple speakers detected',
                  l10n?.multipleSpeakersDesc ?? 'It seems like there are multiple speakers in the recording. Please make sure you are in a quiet location and try again.',
                  okButtonText: l10n?.tryAgain ?? 'Try Again',
                  singleButton: true,
                ),
                barrierDismissible: false,
              );
            } else if (error == 'TOO_SHORT') {
              showDialog(
                context: context,
                builder: (c) => getDialog(
                  context,
                  () {
                    Navigator.pop(context);
                    Navigator.pop(context);
                  },
                  () {},
                  l10n?.invalidRecordingDetected ?? 'Invalid recording detected',
                  l10n?.notEnoughSpeech ?? 'There is not enough speech detected. Please speak more and try again.',
                  okButtonText: l10n?.ok ?? 'Ok',
                  singleButton: true,
                ),
                barrierDismissible: false,
              );
            } else if (error == 'INVALID_RECORDING') {
              showDialog(
                context: context,
                builder: (c) => getDialog(
                  context,
                  () {
                    Navigator.pop(context);
                    Navigator.pop(context);
                  },
                  () {},
                  l10n?.invalidRecordingDetected ?? 'Invalid recording detected',
                  l10n?.invalidRecordingDesc ?? 'Please make sure you speak for at least 5 seconds and not more than 90.',
                  okButtonText: l10n?.ok ?? 'Ok',
                  singleButton: true,
                ),
                barrierDismissible: false,
              );
            } else if (error == "AUTH_REQUIRED") {
              showDialog(
                context: context,
                builder: (c) => getDialog(
                  context,
                  () {
                    Navigator.pop(context);
                  },
                  () {},
                  l10n?.authenticationRequired ?? 'Authentication Required',
                  l10n?.authRequiredDesc ?? 'You need to be signed in to create your voice profile. Please sign in and try again.',
                  okButtonText: l10n?.ok ?? 'Ok',
                  singleButton: true,
                ),
                barrierDismissible: false,
              );
            } else if (error == "ENROLLMENT_FAILED") {
              showDialog(
                context: context,
                builder: (c) => getDialog(
                  context,
                  () {
                    provider.resetSegments();
                    Navigator.pop(context);
                  },
                  () {},
                  l10n?.voiceProfileError ?? 'Voice Profile Error',
                  l10n?.voiceProfileErrorDesc ?? 'Could not save your voice profile. Please check your internet connection and try again.',
                  okButtonText: l10n?.tryAgain ?? 'Try Again',
                  singleButton: true,
                ),
                barrierDismissible: false,
              );
            } else if (error == "ENROLLMENT_VERIFICATION_FAILED") {
              showDialog(
                context: context,
                builder: (c) => getDialog(
                  context,
                  () {
                    provider.resetSegments();
                    Navigator.pop(context);
                  },
                  () {},
                  l10n?.verificationError ?? 'Verification Error',
                  l10n?.verificationErrorDesc ?? 'Your voice profile was not saved correctly. Please try again.',
                  okButtonText: l10n?.tryAgain ?? 'Try Again',
                  singleButton: true,
                ),
                barrierDismissible: false,
              );
            }
          },
          child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.primary,
            appBar: AppBar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              automaticallyImplyLeading: true,
              title: const Text(
                '',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
              actions: [
                !widget.onbording
                    ? IconButton(
                        onPressed: () {
                          final l10n = AppLocalizations.of(context);
                          showDialog(
                            context: context,
                            builder: (c) => getDialog(
                              context,
                              () => Navigator.pop(context),
                              () => Navigator.pop(context),
                              l10n?.howToTakeGoodSample ?? 'How to take a good sample?',
                              l10n?.howToTakeGoodSampleDesc ?? '1. Make sure you are in a quiet place.\n2. Speak clearly and naturally.\n3. Make sure your device is in it\'s natural position, on your neck.\n\nOnce it\'s created, you can always improve it or do it again.',
                              singleButton: true,
                            ),
                          );
                        },
                        icon: const Icon(
                          Icons.question_mark,
                          size: 20,
                        ))
                    : TextButton(
                        onPressed: () {
                          routeToPage(context, const HomePageWrapper(), replace: true);
                        },
                        child: Text(
                          AppLocalizations.of(context)?.skip ?? 'Skip',
                          style: const TextStyle(color: Colors.white, decoration: TextDecoration.underline),
                        ),
                      ),
              ],
              centerTitle: true,
              elevation: 0,
              leading: widget.onbording
                  ? const SizedBox()
                  : IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new),
                      onPressed: () => Navigator.pop(context),
                    ),
            ),
            body: Column(
              children: [
                // Top section: device animation or phone mic icon
                provider.usePhoneMic && provider.startedRecording
                    ? const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: SizedBox(
                          height: 80,
                          child: Center(child: Icon(Icons.mic, color: Colors.white, size: 64)),
                        ),
                      )
                    : const ClipRect(
                        child: DeviceAnimationWidget(
                          sizeMultiplier: 0.7,
                          animatedBackground: true,
                        ),
                      ),
                // Middle section: text content
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: !provider.startedRecording
                        ? Center(
                            child: Text(
                              AppLocalizations.of(context)?.maityNeedsToLearnVoice ?? 'Maity needs to learn your voice to be able to recognise you.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                height: 1.4,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          )
                        : provider.text.isEmpty
                            ? Center(
                                child: provider.percentageCompleted > 0
                                    ? const SizedBox()
                                    : Text(
                                        AppLocalizations.of(context)?.introduceYourself ?? "Introduce\nyourself",
                                        style: const TextStyle(color: Colors.white, fontSize: 24, height: 1.4),
                                        textAlign: TextAlign.center,
                                      ),
                              )
                            : Center(
                                child: ShaderMask(
                                  shaderCallback: (bounds) {
                                    if (provider.text.split(' ').length < 10) {
                                      return const LinearGradient(colors: [Colors.white, Colors.white])
                                          .createShader(bounds);
                                    }
                                    return const LinearGradient(
                                      colors: [Colors.transparent, Colors.white],
                                      stops: [0.0, 0.5],
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                    ).createShader(bounds);
                                  },
                                  blendMode: BlendMode.dstIn,
                                  child: SizedBox(
                                    height: 130,
                                    child: ListView(
                                      controller: _scrollController,
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      children: [
                                        Text(
                                          provider.text,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w400,
                                            height: 1.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                  ),
                ),
                // Bottom section: buttons, progress bar
                Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: !provider.startedRecording
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            provider.isInitialising
                                ? const CircularProgressIndicator(
                                    color: Colors.white,
                                  )
                                : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Primary button: BLE device or phone mic
                                    MaterialButton(
                                      onPressed: () async {
                                        if (provider.device != null) {
                                          await _startWithBleDevice(provider, stopDeviceRecording, restartDeviceRecording);
                                        } else {
                                          await _startWithPhoneMic(provider, stopDeviceRecording, restartDeviceRecording);
                                        }
                                      },
                                      color: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (provider.device == null)
                                            const Padding(
                                              padding: EdgeInsets.only(right: 8),
                                              child: Icon(Icons.mic, color: Colors.black, size: 20),
                                            ),
                                          Text(
                                            provider.device == null
                                                ? (AppLocalizations.of(context)?.usePhoneMic ?? 'Use phone microphone')
                                                : SharedPreferencesUtil().hasSpeakerProfile
                                                    ? (AppLocalizations.of(context)?.doItAgain ?? 'Do it again')
                                                    : (AppLocalizations.of(context)?.getStarted ?? 'Get Started'),
                                            style: const TextStyle(color: Colors.black),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Secondary option: phone mic when device is connected
                                    if (provider.device != null) ...[
                                      const SizedBox(height: 12),
                                      TextButton.icon(
                                        onPressed: () async => _startWithPhoneMic(provider, stopDeviceRecording, restartDeviceRecording),
                                        icon: const Icon(Icons.mic, color: Colors.white70, size: 18),
                                        label: Text(
                                          AppLocalizations.of(context)?.usePhoneMic ?? 'Use phone microphone',
                                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                            const SizedBox(height: 24),
                            const _ProfileStatusPanel(),
                          ],
                        )
                      : provider.profileCompleted
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                              decoration: BoxDecoration(
                                border: const GradientBoxBorder(
                                  gradient: LinearGradient(colors: [
                                    Color.fromARGB(127, 208, 208, 208),
                                    Color.fromARGB(127, 188, 99, 121),
                                    Color.fromARGB(127, 86, 101, 182),
                                    Color.fromARGB(127, 126, 190, 236)
                                  ]),
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: TextButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                },
                                child: Text(
                                  AppLocalizations.of(context)?.allDone ?? "All done!",
                                  style: const TextStyle(color: Colors.white, fontSize: 16),
                                ),
                              ),
                            )
                          : provider.uploadingProfile
                              ? const CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                )
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: MediaQuery.sizeOf(context).width * 0.9,
                                      child: ProgressBarWithPercentage(progressValue: provider.percentageCompleted),
                                    ),
                                    const SizedBox(height: 18),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 40),
                                      child: Text(
                                        provider.message,
                                        style: TextStyle(color: Colors.grey.shade300, fontSize: 14, height: 1.4),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(height: 30),
                                  ],
                                ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// Panel showing voice profile status (cloud + local) and playback button.
class _ProfileStatusPanel extends StatelessWidget {
  const _ProfileStatusPanel();

  @override
  Widget build(BuildContext context) {
    final hasCloud = SharedPreferencesUtil().hasSpeakerProfile;
    final localPath = SharedPreferencesUtil().localSpeakerEmbeddingPath;
    final hasLocal = localPath.isNotEmpty && File(localPath).existsSync();
    final audioPath = SharedPreferencesUtil().getString('speechProfileAudioPath');
    final hasAudio = audioPath.isNotEmpty;

    if (!hasCloud && !hasLocal && !hasAudio) return const SizedBox();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _statusRow('Cloud voice profile', hasCloud),
          const SizedBox(height: 6),
          _statusRow('Local speaker ID', hasLocal),
          if (hasAudio) ...[
            const SizedBox(height: 10),
            _PlayEnrollmentAudioButton(audioPath: audioPath),
          ],
        ],
      ),
    );
  }

  static Widget _statusRow(String label, bool active) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          active ? Icons.check_circle : Icons.cancel_outlined,
          color: active ? Colors.greenAccent : Colors.grey,
          size: 16,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: active ? Colors.white70 : Colors.grey,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

/// Button to play the locally saved enrollment audio for verification.
class _PlayEnrollmentAudioButton extends StatefulWidget {
  final String audioPath;
  const _PlayEnrollmentAudioButton({required this.audioPath});

  @override
  State<_PlayEnrollmentAudioButton> createState() => _PlayEnrollmentAudioButtonState();
}

class _PlayEnrollmentAudioButtonState extends State<_PlayEnrollmentAudioButton> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _player.stop();
      setState(() => _isPlaying = false);
      return;
    }

    final file = File(widget.audioPath);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio file not found. Re-record your voice profile.')),
        );
      }
      return;
    }

    try {
      await _player.setFilePath(widget.audioPath);
      setState(() => _isPlaying = true);
      _player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) setState(() => _isPlaying = false);
        }
      });
      await _player.play();
    } catch (e) {
      debugPrint('[PlayEnrollment] Error: $e');
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _togglePlayback,
      icon: Icon(
        _isPlaying ? Icons.stop : Icons.play_arrow,
        color: Colors.white,
      ),
      label: Text(
        _isPlaying
            ? 'Stop'
            : (AppLocalizations.of(context)?.listenToMySpeechProfile ?? 'Listen to my speech profile'),
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }
}
