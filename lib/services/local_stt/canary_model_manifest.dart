import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/model_manifest.dart';

/// Manifest for NVIDIA Canary 180M Flash (en/es/de/fr, int8 quantized).
///
/// Downloaded as individual files from HuggingFace (same pattern as Parakeet).
/// Uses OfflineCanaryModelConfig with srcLang/tgtLang for language selection.
///
/// Model files:
///   - encoder.int8.onnx  (~133 MB)
///   - decoder.int8.onnx  (~74 MB)
///   - tokens.txt         (~54 KB)
///   - silero_vad.onnx    (~1.8 MB, shared)
///
/// WER Spanish: 3.17% (MLS), 4.90% (Common Voice).
/// Ref: sherpa-onnx OfflineCanaryModelConfig, PR #2272.
class CanaryModelManifest extends LocalSttModelManifest {
  static const String _baseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8/resolve/main';

  @override
  String get modelName =>
      'sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8';

  @override
  String get modelDirName => 'canary-180m-flash';

  @override
  LocalSttModelType get modelType => LocalSttModelType.canary;

  @override
  int get totalExpectedBytes => 218 * 1024 * 1024; // ~218 MB

  @override
  List<LocalSttModelFile> get files => const [
        LocalSttModelFile(
          fileName: 'encoder.int8.onnx',
          url: '$_baseUrl/encoder.int8.onnx',
          expectedBytes: 139460608, // exact: 139,460,608 bytes
        ),
        LocalSttModelFile(
          fileName: 'decoder.int8.onnx',
          url: '$_baseUrl/decoder.int8.onnx',
          expectedBytes: 78007296, // exact: 78,007,296 bytes
        ),
        LocalSttModelFile(
          fileName: 'tokens.txt',
          url: '$_baseUrl/tokens.txt',
          expectedBytes: 54886, // exact: 54,886 bytes
          sizeThreshold: 0.5,
        ),
        LocalSttModelFile(
          fileName: 'silero_vad.onnx',
          url:
              'https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx',
          expectedBytes: 1808 * 1024, // ~1.81 MB (shared with other models)
        ),
      ];
}
