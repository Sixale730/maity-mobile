import 'package:omi/services/stt/local/local_stt_model_type.dart';
import 'package:omi/services/stt/local/model_manifest.dart';

/// Manifest for Moonshine v2 Base ES (Spanish-optimized, quantized).
///
/// Uses Moonshine v2 format (merged decoder) — NOT v1 (4 separate files).
/// Distributed as a single tar.bz2 archive from GitHub releases.
/// After extraction, the model directory contains:
///   - encoder_model.ort      (~20 MB)  — encoder
///   - decoder_model_merged.ort (~41 MB) — merged decoder (v2)
///   - tokens.txt             (~520 KB) — vocabulary
///
/// Silero VAD is downloaded separately (shared with Parakeet).
///
/// References:
/// - PR #3232: C++ runtime for Moonshine v2 (merged Feb 27, 2026)
/// - PR #3245: Dart API for Moonshine v2
/// - Issue #3223: v2 format uses encoder_model + decoder_model_merged
class MoonshineModelManifest extends LocalSttModelManifest {
  static const String _archiveName =
      'sherpa-onnx-moonshine-base-es-quantized-2026-02-27';

  @override
  String get modelName => _archiveName;

  @override
  String get modelDirName => 'moonshine-base-es';

  @override
  LocalSttModelType get modelType => LocalSttModelType.moonshine;

  @override
  int get totalExpectedBytes => 51 * 1024 * 1024; // ~50 MB compressed

  @override
  bool get isArchiveDownload => true;

  @override
  String get archiveUrl =>
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$_archiveName.tar.bz2';

  @override
  int get archiveBytes => 50846902; // exact size from GitHub releases

  @override
  String get archiveInnerDir => _archiveName;

  /// Expected files after extraction (for validation).
  /// Moonshine v2 format: encoder + mergedDecoder (NOT v1's 4 separate files).
  @override
  List<LocalSttModelFile> get files => const [
        LocalSttModelFile(
          fileName: 'encoder_model.ort',
          url: '', // extracted from archive
          expectedBytes: 20964320, // exact: 20,964,320 bytes
        ),
        LocalSttModelFile(
          fileName: 'decoder_model_merged.ort',
          url: '', // extracted from archive
          expectedBytes: 43612200, // exact: 43,612,200 bytes
        ),
        LocalSttModelFile(
          fileName: 'tokens.txt',
          url: '', // extracted from archive
          expectedBytes: 532090, // exact: 532,090 bytes
          sizeThreshold: 0.5, // tokens size can vary
        ),
        LocalSttModelFile(
          fileName: 'silero_vad.onnx',
          url:
              'https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx',
          expectedBytes: 1808 * 1024, // ~1.81 MB (shared with Parakeet)
        ),
      ];
}
