import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/pages/conversation_capturing/page.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/enums.dart';
import 'package:provider/provider.dart';

/// Persistent recording status widget for the dashboard.
/// Shows a quick-start button when idle, or live recording status with controls.
class QuickRecordWidget extends StatelessWidget {
  const QuickRecordWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<CaptureProvider, ({RecordingState state, bool isPaused, int segmentCount})>(
      selector: (_, p) => (
        state: p.recordingState,
        isPaused: p.isPaused,
        segmentCount: p.segments.length,
      ),
      builder: (context, data, _) {
        final isRecording = data.state == RecordingState.record ||
            data.state == RecordingState.deviceRecord ||
            data.state == RecordingState.systemAudioRecord;
        final isPaused = data.isPaused || data.state == RecordingState.pause;
        final isProcessing = data.state == RecordingState.processing;
        final isInitializing = data.state == RecordingState.initialising;
        final isActive = isRecording || isPaused || isInitializing;

        if (isProcessing) {
          return _buildProcessingCard(context);
        }

        if (isActive) {
          return _buildActiveRecordingCard(context, data, isPaused, isInitializing);
        }

        return _buildQuickStartCard(context);
      },
    );
  }

  Widget _buildQuickStartCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        onTap: () async {
          HapticFeedback.heavyImpact();
          final captureProvider = context.read<CaptureProvider>();
          MixpanelManager().phoneMicRecordingStarted();
          await captureProvider.streamRecording();
          if (context.mounted) {
            final topConvoId = context.read<ConversationProvider>().conversations.isNotEmpty
                ? context.read<ConversationProvider>().conversations.first.id
                : null;
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => ConversationCapturingPage(topConversationId: topConvoId),
            ));
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF485DF4), Color(0xFF6C7BF7)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF485DF4).withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            children: [
              Icon(FontAwesomeIcons.microphone, color: Colors.white, size: 20),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Transcripción rápida',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Toca para comenzar a grabar',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(FontAwesomeIcons.circlePlay, color: Colors.white70, size: 28),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveRecordingCard(
    BuildContext context,
    ({RecordingState state, bool isPaused, int segmentCount}) data,
    bool isPaused,
    bool isInitializing,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        onTap: () {
          final captureProvider = context.read<CaptureProvider>();
          final topConvoId = context.read<ConversationProvider>().conversations.isNotEmpty
              ? context.read<ConversationProvider>().conversations.first.id
              : null;
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => ConversationCapturingPage(topConversationId: topConvoId),
          ));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isPaused ? const Color(0xFF2A1800) : const Color(0xFF1A0A0A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isPaused ? const Color(0xFFFF9500).withValues(alpha: 0.4) : const Color(0xFFFE3B30).withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              // Pulsing indicator
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: isPaused ? const Color(0xFFFF9500) : const Color(0xFFFE3B30),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPaused ? 'Grabación en pausa' : (isInitializing ? 'Iniciando...' : 'Grabando...'),
                      style: TextStyle(
                        color: isPaused ? const Color(0xFFFF9500) : const Color(0xFFFE3B30),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (data.segmentCount > 0)
                      Text(
                        '${data.segmentCount} segmento${data.segmentCount == 1 ? '' : 's'}',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                      ),
                  ],
                ),
              ),
              // Quick controls
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Pause/Resume
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      final provider = context.read<CaptureProvider>();
                      if (isPaused) {
                        provider.streamRecording();
                      } else if (data.state == RecordingState.record) {
                        provider.stopStreamRecording();
                      }
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: isPaused ? const Color(0xFF485DF4) : const Color(0xFFFF9500),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: FaIcon(
                          isPaused ? FontAwesomeIcons.play : FontAwesomeIcons.pause,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Stop
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.heavyImpact();
                      final provider = context.read<CaptureProvider>();
                      if (data.state == RecordingState.record) {
                        provider.stopStreamRecording();
                      } else if (isPaused) {
                        provider.streamRecording().then((_) {
                          Future.delayed(const Duration(milliseconds: 300), () {
                            provider.stopStreamRecording();
                          });
                        });
                      }
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFE3B30),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: FaIcon(FontAwesomeIcons.stop, color: Colors.white, size: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F25),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF35343B)),
        ),
        child: const Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2)),
            SizedBox(width: 14),
            Text('Procesando conversación...', style: TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
