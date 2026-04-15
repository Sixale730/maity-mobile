import 'package:omi/services/stt/local/local_stt_model_type.dart';

// ---------------------------------------------------------------------------
// Abstract interface for any local STT model manifest
// ---------------------------------------------------------------------------

/// Describes a single downloadable model file.
class LocalSttModelFile {
  final String fileName;
  final String url;
  final int expectedBytes;
  final double sizeThreshold; // 0.89 = 89% of expected

  const LocalSttModelFile({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
    this.sizeThreshold = 0.89,
  });

  bool validateSize(int actualBytes) =>
      actualBytes >= (expectedBytes * sizeThreshold).toInt();
}

/// Common interface for model manifests (Parakeet, Moonshine, etc.).
abstract class LocalSttModelManifest {
  String get modelName;
  String get modelDirName;
  int get totalExpectedBytes;
  List<LocalSttModelFile> get files;
  LocalSttModelType get modelType;

  /// Whether this model is distributed as a single archive (tar.bz2)
  /// rather than individual files.
  bool get isArchiveDownload => false;

  /// Archive download URL (only relevant when [isArchiveDownload] is true).
  String get archiveUrl => '';

  /// Archive file size in bytes (only relevant when [isArchiveDownload] is true).
  int get archiveBytes => 0;

  /// Directory name inside the archive after extraction.
  String get archiveInnerDir => modelName;
}

// ---------------------------------------------------------------------------
// Parakeet TDT 0.6B v3 manifest
// ---------------------------------------------------------------------------

class ParakeetModelManifest extends LocalSttModelManifest {
  static const String _baseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main';

  @override
  String get modelName => 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';

  @override
  String get modelDirName => 'parakeet-tdt-0.6b-v3';

  @override
  LocalSttModelType get modelType => LocalSttModelType.parakeet;

  @override
  int get totalExpectedBytes => 672 * 1024 * 1024; // ~672 MB

  @override
  List<LocalSttModelFile> get files => const [
        LocalSttModelFile(
          fileName: 'encoder.int8.onnx',
          url: '$_baseUrl/encoder.int8.onnx',
          expectedBytes: 652 * 1024 * 1024, // ~652 MB
        ),
        LocalSttModelFile(
          fileName: 'decoder.int8.onnx',
          url: '$_baseUrl/decoder.int8.onnx',
          expectedBytes: 12 * 1024 * 1024, // ~12 MB
        ),
        LocalSttModelFile(
          fileName: 'joiner.int8.onnx',
          url: '$_baseUrl/joiner.int8.onnx',
          expectedBytes: 6 * 1024 * 1024, // ~6.4 MB
        ),
        LocalSttModelFile(
          fileName: 'tokens.txt',
          url: '$_baseUrl/tokens.txt',
          expectedBytes: 94 * 1024, // ~94 KB
        ),
        LocalSttModelFile(
          fileName: 'silero_vad.onnx',
          url:
              'https://huggingface.co/csukuangfj/vad/resolve/main/silero_vad.onnx',
          expectedBytes: 1808 * 1024, // ~1.81 MB
        ),
      ];

  /// Minimum device RAM in bytes to run the model comfortably
  static const int minimumRamBytes = 6 * 1024 * 1024 * 1024; // 6 GB

  /// iPhone models known to have <6GB RAM
  static const Set<String> lowRamModels = {
    'iPhone10,1', 'iPhone10,2', 'iPhone10,3', 'iPhone10,4', 'iPhone10,5',
    'iPhone10,6', // iPhone 8/X
    'iPhone11,2', 'iPhone11,4', 'iPhone11,6',
    'iPhone11,8', // iPhone XS/XR
    'iPhone12,1', 'iPhone12,3', 'iPhone12,5',
    'iPhone12,8', // iPhone 11/SE2
    'iPhone13,1', 'iPhone13,2', 'iPhone13,3',
    'iPhone13,4', // iPhone 12
    'iPhone14,4', 'iPhone14,5', 'iPhone14,6', 'iPhone14,7',
    'iPhone14,8', // iPhone 13/SE3
  };
}
