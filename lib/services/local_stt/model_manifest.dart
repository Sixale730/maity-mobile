/// Manifest for Parakeet TDT 0.6B v3 model files.
/// These are the ONNX model files needed for sherpa_onnx OfflineRecognizer.
class ParakeetModelFile {
  final String fileName;
  final String url;
  final int expectedBytes;
  final double sizeThreshold; // 0.89 = 89% of expected

  const ParakeetModelFile({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
    this.sizeThreshold = 0.89,
  });

  bool validateSize(int actualBytes) =>
      actualBytes >= (expectedBytes * sizeThreshold).toInt();
}

class ParakeetModelManifest {
  static const String modelName =
      'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';
  static const String baseUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main';
  static const String modelDirName = 'parakeet-tdt-0.6b-v3';

  /// Total expected download size in bytes (~672 MB)
  static const int totalExpectedBytes = 672 * 1024 * 1024;

  static const List<ParakeetModelFile> files = [
    ParakeetModelFile(
      fileName: 'encoder.int8.onnx',
      url: '$baseUrl/encoder.int8.onnx',
      expectedBytes: 652 * 1024 * 1024, // ~652 MB
    ),
    ParakeetModelFile(
      fileName: 'decoder.int8.onnx',
      url: '$baseUrl/decoder.int8.onnx',
      expectedBytes: 12 * 1024 * 1024, // ~12 MB
    ),
    ParakeetModelFile(
      fileName: 'joiner.int8.onnx',
      url: '$baseUrl/joiner.int8.onnx',
      expectedBytes: 6 * 1024 * 1024, // ~6.4 MB
    ),
    ParakeetModelFile(
      fileName: 'tokens.txt',
      url: '$baseUrl/tokens.txt',
      expectedBytes: 94 * 1024, // ~94 KB
    ),
    ParakeetModelFile(
      fileName: 'silero_vad.onnx',
      url:
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
      expectedBytes: 2 * 1024 * 1024, // ~2 MB
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
