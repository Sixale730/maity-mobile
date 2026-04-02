import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    Future<void> stopRecordingAndProcess() async {
      final state = provider.recordingState;
      if (state == RecordingState.record) {
        await provider.stopStreamRecording();
      } else if (state == RecordingState.deviceRecord) {
        await provider.stopStreamDeviceRecording();
      } else if (state == RecordingState.systemAudioRecord) {
        await provider.stopSystemAudioRecording();
      } else if (state == RecordingState.pause || provider.isPaused) {
        if (provider.havingRecordingDevice) {
          await provider.stopStreamDeviceRecording();
        } else {
          await provider.streamRecording();
          await Future.delayed(const Duration(milliseconds: 300));
          await provider.stopStreamRecording();
        }
      } else if (state == RecordingState.initialising) {
        provider.clearTranscripts();
        provider.updateRecordingState(RecordingState.stop);
      }
    }

    // If no segments yet, just stop and go back
    if (provider.segments.isEmpty && provider.photos.isEmpty) {
      await stopRecordingAndProcess();
      if (mounted) Navigator.of(context).pop();
      return;
    }

    if (!showSummarizeConfirmation) {
      await stopRecordingAndProcess();
      if (mounted) Navigator.of(context).pop();
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
                if (mounted) Navigator.of(context).pop();
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Selector<CaptureProvider, ({int segmentsVersion, int photosCount, bool hasData, RecordingState recordingState, bool isPaused})>(
      selector: (_, p) => (
        segmentsVersion: p.segmentsVersion,
        photosCount: p.photos.length,
        hasData: p.hasTranscripts || p.photos.isNotEmpty,
        recordingState: p.recordingState,
        isPaused: p.isPaused,
      ),
      builder: (context, snapshot, child) {
        final provider = context.read<CaptureProvider>();
        final deviceProvider = context.read<DeviceProvider>();
        final isProcessing = snapshot.recordingState == RecordingState.processing;
        final isPaused = snapshot.isPaused ||
            snapshot.recordingState == RecordingState.pause ||
            snapshot.recordingState == RecordingState.stop;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final state = provider.recordingState;
            final isActiveRecording = state == RecordingState.record ||
                state == RecordingState.deviceRecord ||
                state == RecordingState.systemAudioRecord ||
                state == RecordingState.initialising;
            // Active recording: just go back — session continues in background
            // and the user can re-open via FAB.
            if (!isActiveRecording && provider.segments.isEmpty && provider.photos.isEmpty && !provider.hasUnprocessedAudio) {
              await provider.cancelRecording();
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Scaffold(
            key: scaffoldKey,
            backgroundColor: isPaused ? const Color(0xFF1A1000) : Theme.of(context).colorScheme.primary,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              backgroundColor: isPaused ? const Color(0xFF2A1800) : Theme.of(context).colorScheme.primary,
              title: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () {
                      Navigator.pop(context);
                      return;
                    },
                    icon: const Icon(Icons.arrow_back_rounded, size: 24.0),
                  ),
                  const SizedBox(width: 4),
                  // Paused indicator
                  if (isPaused && !isProcessing)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF9500).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFF9500).withValues(alpha: 0.4)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.pause_circle_filled, color: Color(0xFFFF9500), size: 16),
                          SizedBox(width: 4),
                          Text('PAUSADO', style: TextStyle(color: Color(0xFFFF9500), fontSize: 12, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  if (!isPaused) const SizedBox(width: 4),
                  Expanded(child: Text(() {
                    if (isProcessing) {
                      return AppLocalizations.of(context)?.processing ?? "Procesando...";
                    }
                    if (isPaused) return '';
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
                        provider.segments.isEmpty && provider.photos.isEmpty
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
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F25),
                      borderRadius: BorderRadius.circular(40),
                      border: Border.all(color: const Color(0xFF35343B), width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text('Procesando...', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F25),
                      borderRadius: BorderRadius.circular(40),
                      border: Border.all(color: const Color(0xFF35343B), width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Cancel button
                        _buildControlButton(
                          icon: FontAwesomeIcons.xmark,
                          label: 'Cancelar',
                          color: const Color(0xFF35343B),
                          iconColor: Colors.white70,
                          onTap: () => _cancelConversation(provider),
                        ),
                        const SizedBox(width: 8),
                        // Pause/Resume button
                        _buildControlButton(
                          icon: provider.isPaused ? FontAwesomeIcons.play : FontAwesomeIcons.pause,
                          label: provider.isPaused ? 'Reanudar' : 'Pausar',
                          color: provider.isPaused ? const Color(0xFF485DF4) : const Color(0xFFFF9500),
                          iconColor: Colors.white,
                          onTap: () => _togglePause(provider),
                        ),
                        const SizedBox(width: 8),
                        // Stop button
                        _buildControlButton(
                          icon: FontAwesomeIcons.stop,
                          label: 'Detener',
                          color: const Color(0xFFFE3B30),
                          iconColor: Colors.white,
                          onTap: () => _stopConversation(provider),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Center(child: FaIcon(icon, color: iconColor, size: 18)),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  void _cancelConversation(CaptureProvider provider) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F25),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cancelar grabación', style: TextStyle(color: Colors.white)),
        content: const Text(
          '¿Deseas descartar la grabación actual? Se perderá todo lo capturado.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Continuar grabando', style: TextStyle(color: Color(0xFF485DF4))),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final cancelState = provider.recordingState;
              if (cancelState == RecordingState.record) {
                await provider.stopStreamRecording();
              } else if (cancelState == RecordingState.deviceRecord) {
                await provider.stopStreamDeviceRecording();
              } else if (cancelState == RecordingState.systemAudioRecord) {
                await provider.stopSystemAudioRecording();
              } else if (cancelState == RecordingState.pause || provider.isPaused) {
                if (provider.havingRecordingDevice) {
                  await provider.stopStreamDeviceRecording();
                } else {
                  await provider.stopStreamRecording();
                }
              }
              provider.clearTranscripts();
              provider.updateRecordingState(RecordingState.stop);
              if (mounted) Navigator.of(context).pop();
            },
            child: const Text('Descartar', style: TextStyle(color: Color(0xFFFE3B30))),
          ),
        ],
      ),
    );
  }

  void _togglePause(CaptureProvider provider) {
    final state = provider.recordingState;
    // Device recording: pause/resume via device-specific methods
    if (state == RecordingState.deviceRecord) {
      provider.pauseDeviceRecording();
    } else if (provider.havingRecordingDevice && (state == RecordingState.pause || provider.isPaused)) {
      provider.resumeDeviceRecording();
    }
    // Phone mic / system audio
    else if (state == RecordingState.record || state == RecordingState.systemAudioRecord) {
      provider.stopStreamRecording();
    } else if (provider.isPaused || state == RecordingState.pause || state == RecordingState.stop) {
      provider.streamRecording();
    }
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
