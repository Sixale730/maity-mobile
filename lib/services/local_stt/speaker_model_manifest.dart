/// Manifest for the 3D-Speaker CAM++ speaker embedding model.
/// Used for on-device speaker identification during local STT.
class SpeakerModelManifest {
  static const String modelFileName =
      '3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx';

  static const String url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$modelFileName';

  /// Embedding dimension produced by this model.
  static const int embeddingDim = 192;

  /// Subdirectory under getApplicationSupportDirectory().
  static const String modelDirName = 'speaker-campplus';

  /// Expected file size in bytes (~28.2 MB).
  static const int expectedBytes = 29570048;

  /// Minimum fraction of expectedBytes to consider valid.
  static const double sizeThreshold = 0.89;

  /// User embedding file name (192 floats × 4 bytes = 768 bytes).
  static const String embeddingFileName = 'user_embedding.bin';

  /// Expected embedding file size in bytes.
  static const int embeddingFileBytes = embeddingDim * 4; // 768

  static bool validateModelSize(int actualBytes) =>
      actualBytes >= (expectedBytes * sizeThreshold).toInt();
}
