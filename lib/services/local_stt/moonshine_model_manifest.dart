import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/model_manifest.dart';

/// Manifest for Moonshine v2 Base ES (Spanish-optimized, quantized).
///
/// Distributed as a single tar.bz2 archive from GitHub releases.
/// After extraction, the model directory contains:
///   - preprocess.onnx
///   - encode.int8.onnx
///   - uncached_decode.int8.onnx
///   - cached_decode.int8.onnx
///   - tokens.txt
///
/// Silero VAD is downloaded separately (shared with Parakeet).
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
  @override
  List<LocalSttModelFile> get files => const [
        LocalSttModelFile(
          fileName: 'preprocess.onnx',
          url: '', // extracted from archive
          expectedBytes: 14 * 1024 * 1024, // ~14 MB (estimated from EN base)
        ),
        LocalSttModelFile(
          fileName: 'encode.int8.onnx',
          url: '', // extracted from archive
          expectedBytes: 15 * 1024 * 1024, // ~15 MB (smaller, quantized ES)
        ),
        LocalSttModelFile(
          fileName: 'uncached_decode.int8.onnx',
          url: '', // extracted from archive
          expectedBytes: 15 * 1024 * 1024, // ~15 MB (smaller, quantized ES)
        ),
        LocalSttModelFile(
          fileName: 'cached_decode.int8.onnx',
          url: '', // extracted from archive
          expectedBytes: 12 * 1024 * 1024, // ~12 MB (smaller, quantized ES)
        ),
        LocalSttModelFile(
          fileName: 'tokens.txt',
          url: '', // extracted from archive
          expectedBytes: 100 * 1024, // ~100 KB
          sizeThreshold: 0.1, // tokens.txt can vary greatly
        ),
        LocalSttModelFile(
          fileName: 'silero_vad.onnx',
          url:
              'https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx',
          expectedBytes: 1808 * 1024, // ~1.81 MB (shared with Parakeet)
        ),
      ];
}
