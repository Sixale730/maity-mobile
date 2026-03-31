import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/pages/capture/widgets/widgets.dart';
import 'package:omi/pages/conversation_detail/page.dart';
import 'package:omi/pages/conversation_detail/widgets/name_speaker_sheet.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/connectivity_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/widgets/confirmation_dialog.dart';

import 'package:provider/provider.dart';

class ConversationCapturingPage extends StatefulWidget {
  final String? topConversationId;

  const ConversationCapturingPage({
    super.key,
    this.topConversationId,
  });

  @override
  State<ConversationCapturingPage> createState() => _ConversationCapturingPageState();
}

class _ConversationCapturingPageState extends State<ConversationCapturingPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  TabController? _controller;
  late bool showSummarizeConfirmation;
  bool _deferTranscript = false;

  @override
  void initState() {
    _controller = TabController(length: 2, vsync: this, initialIndex: 0);
    showSummarizeConfirmation = SharedPreferencesUtil().showSummarizeConfirmation;
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Deferred rendering: on pause, mark transcript for deferral so the first
    // frame after resume renders a lightweight placeholder instead of the heavy
    // TranscriptWidget. The real list loads on the second frame via postFrameCallback.
    if (state == AppLifecycleState.paused && mounted) {
      setState(() => _deferTranscript = true);
    }
    if (state == AppLifecycleState.resumed && mounted && _deferTranscript) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _deferTranscript = false);
      });
    }
  }

  int convertDateTimeToSeconds(DateTime dateTime) {
    DateTime now = DateTime.now();
    Duration difference = now.difference(dateTime);

    return difference.inSeconds;
  }

  String convertToHHMMSS(int seconds) {
    int hours = seconds ~/ 3600;
    int minutes = (seconds % 3600) ~/ 60;
    int remainingSeconds = seconds % 60;

    String twoDigits(int n) => n.toString().padLeft(2, '0');

    return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(remainingSeconds)}';
  }

  void _pushNewConversation(BuildContext context, conversation) async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (c) => ConversationDetailPage(
          conversation: conversation,
        ),
      ));
    });
  }

  Future<void> _stopConversation(CaptureProvider provider) async {
    if (provider.segments.isNotEmpty || provider.photos.isNotEmpty) {
      // Helper function to stop recording (finalization runs in background)
      Future<void> stopRecordingAndProcess() async {
        // Stop any active recording (phone mic, BLE device, or system audio)
        // The stop methods now transition to processing state and finalize in background
        if (provider.recordingState == RecordingState.record) {
          await provider.stopStreamRecording();
        } else if (provider.recordingState == RecordingState.deviceRecord) {
          await provider.stopStreamDeviceRecording();
        } else if (provider.recordingState == RecordingState.systemAudioRecord) {
          await provider.stopSystemAudioRecording();
        }
      }

      if (!showSummarizeConfirmation) {
        await stopRecordingAndProcess();
        Navigator.of(context).pop();
        return;
      }
      showDialog(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setState) {
              final timeoutDuration = SharedPreferencesUtil().conversationSilenceDuration;
              String timeoutText;
              if (timeoutDuration == -1) {
                timeoutText = AppLocalizations.of(context)?.conversationEndsManually ?? "Conversation will only end manually.";
              } else {
                final minutes = timeoutDuration ~/ 60;
                final suffix = minutes == 1 ? '' : 's';
                timeoutText =
                    AppLocalizations.of(context)?.conversationSummarizedAfter(minutes, suffix) ?? "Conversation is summarized after $minutes minute$suffix of no speech.";
              }

              return ConfirmationDialog(
                title: AppLocalizations.of(context)?.finishedConversation ?? "Finished Conversation?",
                description:
                    "${AppLocalizations.of(context)?.stopRecordingConfirm ?? 'Are you sure you want to stop recording and summarize the conversation now?'}\n\n${AppLocalizations.of(context)?.hints ?? 'Hints'}: $timeoutText",
                checkboxValue: !showSummarizeConfirmation,
                checkboxText: AppLocalizations.of(context)?.dontAskAgain ?? "Don't ask me again",
                onCheckboxChanged: (value) {
                  setState(() {
                    showSummarizeConfirmation = !value;
                  });
                },
                onCancel: () {
                  Navigator.of(dialogContext).pop();
                },
                onConfirm: () async {
                  SharedPreferencesUtil().showSummarizeConfirmation = showSummarizeConfirmation;
                  await stopRecordingAndProcess();
                  Navigator.of(dialogContext).pop();
                  Navigator.of(context).pop();
                },
              );
            },
          );
        },
      );
    } else {
      // No content: cancel recording cleanly and navigate back
      await provider.cancelRecording();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Selector<CaptureProvider, ({int segmentsVersion, int photosCount, bool hasData, RecordingState recordingState})>(
      selector: (_, p) => (
        segmentsVersion: p.segmentsVersion,
        photosCount: p.photos.length,
        hasData: p.hasTranscripts || p.photos.isNotEmpty,
        recordingState: p.recordingState,
      ),
      builder: (context, snapshot, child) {
        final provider = context.read<CaptureProvider>();
        final deviceProvider = context.read<DeviceProvider>();
        final isProcessing = snapshot.recordingState == RecordingState.processing;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final state = provider.recordingState;
            final isActiveRecording = state == RecordingState.record ||
                state == RecordingState.deviceRecord ||
                state == RecordingState.systemAudioRecord ||
                state == RecordingState.initialising;
            if (isActiveRecording && provider.segments.isEmpty && provider.photos.isEmpty && !provider.hasUnprocessedAudio) {
              await provider.cancelRecording();
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Scaffold(
            key: scaffoldKey,
            backgroundColor: Theme.of(context).colorScheme.primary,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              backgroundColor: Theme.of(context).colorScheme.primary,
              title: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () {
                      Navigator.maybePop(context);
                    },
                    icon: const Icon(Icons.arrow_back_rounded, size: 24.0),
                  ),
                  const SizedBox(width: 4),
                  Text(isProcessing ? "" : (provider.photos.isNotEmpty ? "" : "")),
                  const SizedBox(width: 4),
                  Expanded(child: Text(() {
                    if (isProcessing) {
                      return AppLocalizations.of(context)?.processing ?? "Procesando...";
                    }
                    final listeningText = AppLocalizations.of(context)?.listening ?? "Listening";
                    final sttProvider = provider.activeSttProvider;
                    if (sttProvider != null) {
                      return '$listeningText · ${SttProviderConfig.get(sttProvider).displayName}';
                    }
                    return listeningText;
                  }())),
                ],
              ),
            ),
            body: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 0),
                    child: TabBarView(
                      controller: _controller,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        // Transcripts, photos
                        _deferTranscript
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.only(top: 50.0),
                                  child: CircularProgressIndicator(color: Colors.white),
                                ),
                              )
                            : provider.segments.isEmpty && provider.photos.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 50.0),
                                  child: Text(AppLocalizations.of(context)?.waitingForTranscript ?? "Waiting for transcript..."),
                                ),
                              )
                            : getTranscriptWidget(
                                false,
                                provider.segments,
                                provider.photos,
                                deviceProvider.connectedDevice,
                                bottomMargin: 150,
                                suggestions: provider.suggestionsBySegmentId,
                                taggingSegmentIds: provider.taggingSegmentIds,
                                onAcceptSuggestion: (suggestion) {
                                  provider.assignSpeakerToConversation(suggestion.speakerId, suggestion.personId,
                                      suggestion.personName, [suggestion.segmentId]);
                                },
                                editSegment: (segmentId, speakerId) {
                                  final connectivityProvider =
                                      Provider.of<ConnectivityProvider>(context, listen: false);
                                  if (!connectivityProvider.isConnected) {
                                    ConnectivityProvider.showNoInternetDialog(context);
                                    return;
                                  }
                                  showModalBottomSheet(
                                      context: context,
                                      isScrollControlled: true,
                                      backgroundColor: Colors.black,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                                      ),
                                      builder: (context) {
                                        final suggestion = provider.suggestionsBySegmentId.values.firstWhere(
                                            (s) => s.speakerId == speakerId,
                                            orElse: () => SpeakerLabelSuggestionEvent.empty());
                                        return NameSpeakerBottomSheet(
                                          speakerId: speakerId,
                                          segmentId: segmentId,
                                          segments: provider.segments,
                                          suggestion: suggestion,
                                          onSpeakerAssigned: (speakerId, personId, personName, segmentIds) async {
                                            await provider.assignSpeakerToConversation(
                                                speakerId, personId, personName, segmentIds);
                                          },
                                        );
                                      });
                                },
                              ),
                        // Summary Tab
                        Center(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 32.0).copyWith(bottom: 50.0), // Adjust padding
                            child: Text(
                              provider.segments.isEmpty && provider.photos.isEmpty
                                  ? AppLocalizations.of(context)?.noSummaryYet ?? "No summary yet"
                                  : _getTimeoutDisplayText(context),
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: provider.segments.isEmpty ? 16 : 22),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
            floatingActionButton: isProcessing
                ? Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: const Color(0xFF35343B),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          spreadRadius: 2,
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    ),
                  )
                : (snapshot.recordingState == RecordingState.record ||
                        snapshot.recordingState == RecordingState.deviceRecord ||
                        snapshot.recordingState == RecordingState.systemAudioRecord ||
                        snapshot.recordingState == RecordingState.initialising)
                    ? Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              spreadRadius: 2,
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: IconButton(
                          onPressed: () => _stopConversation(provider),
                          icon: const FaIcon(
                            FontAwesomeIcons.stop,
                            color: Colors.white,
                            size: 20.0,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      )
                    : null,
          ),
        );
      },
    );
  }

  String _getTimeoutDisplayText(BuildContext context) {
    final timeoutDuration = SharedPreferencesUtil().conversationSilenceDuration;
    if (timeoutDuration == -1) {
      return "${AppLocalizations.of(context)?.conversationEndsManually ?? 'Conversation will only end manually.'} 🤫";
    } else {
      final minutes = timeoutDuration ~/ 60;
      final suffix = minutes == 1 ? '' : 's';
      return "${AppLocalizations.of(context)?.conversationSummarizedAfter(minutes, suffix) ?? 'Conversation is summarized after $minutes minute$suffix of no speech.'} 🤫";
    }
  }
}

String transcriptElapsedTime(String timepstamp) {
  timepstamp = timepstamp.split(' - ')[1];
  return timepstamp;
}
