/// Identifies the on-device STT model variant used by LocalSttEngine.
enum LocalSttModelType {
  /// NVIDIA Parakeet TDT 0.6B v3 (~672 MB, 25 languages, auto-detect).
  parakeet,

  /// Moonshine v2 Base ES (~50 MB compressed, Spanish-optimized).
  moonshine,

  /// NVIDIA Canary 180M Flash (~208 MB, en/es/de/fr, best Spanish WER).
  canary;

  static LocalSttModelType fromString(String value) {
    return LocalSttModelType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => LocalSttModelType.parakeet,
    );
  }
}
