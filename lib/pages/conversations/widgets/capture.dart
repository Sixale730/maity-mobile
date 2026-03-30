import 'package:flutter/material.dart';
import 'package:omi/pages/capture/widgets/widgets.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
import 'package:provider/provider.dart';

class LiteCaptureWidget extends StatefulWidget {
  const LiteCaptureWidget({super.key});

  @override
  State<LiteCaptureWidget> createState() => LiteCaptureWidgetState();
}

class LiteCaptureWidgetState extends State<LiteCaptureWidget> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  setHasTranscripts(bool hasTranscripts) {
    context.read<CaptureProvider>().setHasTranscripts(hasTranscripts);
  }

  @override
  void initState() {
    WavBytesUtil.clearTempWavFiles();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Use Selector on segmentsVersion to only rebuild when segments actually change,
    // not on every notifyListeners() call (e.g., metrics, connection state).
    return Selector<CaptureProvider, int>(
      selector: (_, p) => p.segmentsVersion,
      builder: (context, _, child) {
        final provider = context.read<CaptureProvider>();
        final deviceProvider = context.read<DeviceProvider>();
        return getLiteTranscriptWidget(
          provider.segments,
          provider.photos,
          deviceProvider.connectedDevice,
          vadSpeechActive: provider.vadSpeechActive,
        );
      },
    );
  }
}
