import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:omi/backend/http/api/speech_profile.dart';
import 'package:omi/backend/http/api/users.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/audio/audio_processing_utils.dart' as audio;
import 'package:omi/services/audio/pitch_utils.dart' as pitch;
import 'package:omi/services/audio/spectral_utils.dart' as spectral;
import 'package:omi/services/audio/audio_augmentation.dart' as aug;
import 'package:omi/services/devices.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/stt/local/local_stt_engine_service.dart';
import 'package:omi/services/speaker/speaker_types.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/services/stt/local/speaker_embedding_service.dart';
import 'package:omi/services/stt/local/speaker_model_manifest.dart';
import 'package:omi/services/voice_profile_service.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
import 'package:path_provider/path_provider.dart';

class SpeechProfileProvider extends ChangeNotifier
    with MessageNotifierMixin
    implements IDeviceServiceSubsciption {
  DeviceProvider? deviceProvider;
  bool? permissionEnabled;
  bool loading = false;
  BtDevice? device;

  bool _usePhoneMic = false;
  bool get usePhoneMic => _usePhoneMic;

  final targetWordsCount = 70;
  final maxDuration = 150;

  StreamSubscription<OnConnectionStateChangedEvent>? connectionStateListener;
  List<TranscriptSegment> segments = [];
  double? streamStartedAtSecond;
  late WavBytesUtil audioStorage;
  StreamSubscription? _bleBytesStream;

  LocalSttEngineService? _engine;

  bool startedRecording = false;
  double percentageCompleted = 0;
  bool uploadingProfile = false;
  bool profileCompleted = false;
  Timer? forceCompletionTimer;

  bool isInitialising = false;
  bool isInitialised = false;

  String text = '';
  String message = '';

  late Function? _finalizedCallback;

  /// only used during onboarding /////
  String loadingText = 'Uploading your voice profile....';
  ServerConversation? conversation;

  /////////////////////////////////

  void updateLoadingText(String text) {
    loadingText = text;
    notifyListeners();
  }

  void setInitialising(bool value) {
    isInitialising = value;
    notifyListeners();
  }

  void setInitialised(bool value) {
    isInitialised = value;
    notifyListeners();
  }

  void setProviders(DeviceProvider provider) {
    deviceProvider = provider;
    notifyListeners();
  }

  Future<void> updateDevice() async {
    if (device == null) {
      await deviceProvider?.scanAndConnectToDevice();
      device = deviceProvider?.connectedDevice;
    }
    notifyListeners();
  }

  Future<void> initialise({Function? finalizedCallback, bool usePhoneMic = false}) async {
    if (usePhoneMic) {
      return _initialiseWithPhoneMic(finalizedCallback: finalizedCallback);
    }
    _finalizedCallback = finalizedCallback;
    setInitialising(true);
    device = deviceProvider?.connectedDevice;

    BleAudioCodec codec = await _getAudioCodec(device!.id);
    audioStorage = WavBytesUtil(codec: codec, framesPerSecond: codec.getFramesPerSecond());
    await _initiateWebsocket(codec: codec, force: true);

    if (device != null) await initiateFriendAudioStreaming();
    if (_engine?.isConnected != true) {
      // wait for websocket to connect
      await Future.delayed(const Duration(seconds: 2));
    }

    setInitialising(false);
    setInitialised(true);
    // initiateConnectionListener();
    notifyListeners();
  }

  Future<void> _initialiseWithPhoneMic({Function? finalizedCallback}) async {
    _finalizedCallback = finalizedCallback;
    setInitialising(true);
    _usePhoneMic = true;

    const codec = BleAudioCodec.pcm16;
    audioStorage = WavBytesUtil(codec: codec, framesPerSecond: 100);
    await _initiateWebsocket(codec: codec, force: true, sampleRate: 16000);
    await _startPhoneMicStreaming();

    if (_engine?.isConnected != true) {
      await Future.delayed(const Duration(seconds: 2));
    }

    setInitialising(false);
    setInitialised(true);
    notifyListeners();
  }

  Future<void> _startPhoneMicStreaming() async {
    await ServiceManager.instance().mic.start(
      onByteReceived: (Uint8List bytes) {
        if (bytes.isEmpty) return;
        audioStorage.storeRawAudioBytes(bytes);
        if (_engine?.isConnected == true) {
          _engine?.pushAudio(bytes);
        }
      },
      onRecording: () {
        debugPrint('[SpeechProfile] Phone mic recording started');
      },
      onStop: () {
        debugPrint('[SpeechProfile] Phone mic recording stopped');
      },
    );
  }

  void updateStartedRecording(bool value) {
    startedRecording = value;
    notifyListeners();
  }

  changeLoadingState(bool value) {
    loading = value;
    notifyListeners();
  }

  initiateConnectionListener() async {
    if (device == null || connectionStateListener != null) return;
    ServiceManager.instance().device.subscribe(this, this);
  }

  Future<void> _initiateWebsocket({required BleAudioCodec codec, bool force = false, int? sampleRate}) async {
    // Enrollment uses local STT directly — no cloud socket.
    final engine = _buildEnrollmentEngine();
    if (engine == null) {
      throw Exception('Local STT model not configured for enrollment');
    }
    engine.onSegments = onSegmentReceived;
    engine.onError = (err, _) => onError(err);
    final ok = await engine.connect();
    if (!ok) {
      throw Exception('Can not start speech profile engine');
    }
    _engine = engine;
  }

  /// Instantiate the same [LocalSttEngineService] configuration used by the
  /// recording pipeline, so enrollment transcription quality matches what the
  /// user will see in real sessions.
  LocalSttEngineService? _buildEnrollmentEngine() {
    final prefs = SharedPreferencesUtil();
    final modelPath = prefs.localSttModelPath;
    if (modelPath.isEmpty) return null;

    String? speakerModelPath;
    Uint8List? userEmbeddingBytes;
    final speakerPath = prefs.speakerModelPath;
    final embeddingPath = prefs.localSpeakerEmbeddingPath;
    if (speakerPath.isNotEmpty && embeddingPath.isNotEmpty) {
      final f = File(embeddingPath);
      if (f.existsSync()) {
        final bytes = f.readAsBytesSync();
        if (bytes.length % 4 == 0 && bytes.isNotEmpty) {
          speakerModelPath = speakerPath;
          userEmbeddingBytes = bytes;
        }
      }
    }

    return LocalSttEngineService(
      modelPath: modelPath,
      speakerModelPath: speakerModelPath,
      userEmbeddingBytes: userEmbeddingBytes,
      maxSpeechDuration: 20.0,
    );
  }

  _handleCompletion() async {
    if (uploadingProfile || profileCompleted) return;
    String text = segments.map((e) => e.text).join(' ').trim();
    int wordsCount = text.split(' ').length;
    percentageCompleted = (wordsCount / targetWordsCount).clamp(0, 1);
    notifyListeners();
    if (percentageCompleted == 1) {
      await finalize();
    }
    notifyListeners();
  }

  Future finalize() async {
    try {
      if (uploadingProfile || profileCompleted) return;

      // Validar que el usuario esté autenticado ANTES de procesar
      final userId = SupabaseAuthService.instance.maityUserId;
      if (userId == null) {
        debugPrint('[SpeechProfile] ERROR: maityUserId is null - user not authenticated');
        notifyError('AUTH_REQUIRED');
        return;
      }

      int duration = segments.isEmpty ? 0 : segments.last.end.toInt();
      if (duration < 10 || duration > 155) {
        if (percentageCompleted < 80) {
          notifyError('NO_SPEECH');
          return;
        }
      }

      String text = segments.map((e) => e.text).join(' ').trim();
      if (text.split(' ').length < (targetWordsCount / 2)) {
        // 25 words
        notifyError('TOO_SHORT');
        return;
      }
      uploadingProfile = true;
      notifyListeners();
      await _engine?.disconnect();
      _engine = null;
      forceCompletionTimer?.cancel();
      connectionStateListener?.cancel();
      _bleBytesStream?.cancel();
      if (_usePhoneMic) {
        ServiceManager.instance().mic.stop();
      }

      updateLoadingText('Memorizing your voice...');
      var data = await audioStorage.createWavFile(filename: 'speaker_profile.wav');

      // Enroll voice embedding for speaker verification
      updateLoadingText('Creating voice profile...');
      final enrollSuccess = await VoiceProfileService.enrollVoiceProfile(
        userId: userId,
        audioFile: data.item1,
      );

      if (!enrollSuccess) {
        debugPrint('[SpeechProfile] Voice embedding enrollment failed');
        uploadingProfile = false;
        notifyError('ENROLLMENT_FAILED');
        return;
      }
      debugPrint('[SpeechProfile] Voice embedding enrolled successfully');

      // Verificar que el perfil se guardó correctamente en Supabase
      updateLoadingText('Verifying voice profile...');
      final profileStatus = await VoiceProfileService.getProfileStatus(userId);
      if (!profileStatus.hasProfile) {
        debugPrint('[SpeechProfile] Voice profile verification failed - profile not found in database');
        uploadingProfile = false;
        notifyError('ENROLLMENT_VERIFICATION_FAILED');
        return;
      }
      debugPrint('[SpeechProfile] Voice profile verified successfully');

      // Legacy: upload to omi backend (if enabled)
      try {
        await uploadProfile(data.item1);
      } catch (e) {
        debugPrint('[SpeechProfile] Legacy upload failed: $e');
      }

      updateLoadingText('Personalizing your experience...');
      SharedPreferencesUtil().hasSpeakerProfile = true;

      // Extract and save local speaker embedding (for on-device speaker ID).
      // Use data.item2 (frames copy) because createWavFile() clears audioStorage.
      try {
        await _extractAndSaveLocalEmbedding(enrollmentFrames: data.item2);
      } catch (e) {
        debugPrint('[SpeechProfile] Local embedding extraction failed: $e');
        // Non-fatal: cloud enrollment already succeeded
      }

      uploadingProfile = false;
      profileCompleted = true;
      text = '';
      updateLoadingText("You're all set!");
      notifyListeners();
    } finally {
      if (_finalizedCallback != null) {
        _finalizedCallback!();
      }
    }
  }

  /// Extract a local speaker embedding from enrollment audio using the
  /// on-device CAM++ model and save it to disk for use during local STT.
  Future<void> _extractAndSaveLocalEmbedding({List<List<int>>? enrollmentFrames}) async {
    final speakerModelPath = SharedPreferencesUtil().speakerModelPath;
    if (speakerModelPath.isEmpty) {
      debugPrint(
          '[SpeechProfile] Speaker model not downloaded, skipping local embedding');
      return;
    }

    final allFrames = enrollmentFrames ?? audioStorage.frames;
    if (allFrames.isEmpty) {
      debugPrint(
          '[SpeechProfile] No audio frames available for local embedding');
      return;
    }

    // Concatenate all PCM16 frames into one buffer
    final totalBytes = allFrames.fold<int>(0, (sum, f) => sum + f.length);
    final pcm16 = Uint8List(totalBytes);
    int offset = 0;
    for (final frame in allFrames) {
      pcm16.setRange(offset, offset + frame.length, frame);
      offset += frame.length;
    }

    debugPrint(
        '[SpeechProfile] Extracting local embedding from $totalBytes bytes of audio');

    final service = SpeakerEmbeddingService();
    try {
      service.initialize(speakerModelPath);
      final embedding = service.extractEmbeddingFromPcm16(pcm16);

      if (embedding.isEmpty) {
        debugPrint('[SpeechProfile] Failed to extract local embedding');
        return;
      }

      // Convert to Float32 for augmentation + profile extraction
      final samples = audio.pcm16ToFloat32(pcm16);
      final cleaned = audio.normalizeAudio(audio.highPassFilter80Hz(samples));

      // Augmented embedding: average original + 6 augmented copies for robustness
      final augmentedEmbedding = _computeAugmentedEmbedding(service, embedding, cleaned);

      // Build acoustic profile from clean enrollment audio
      final profile = _buildAcousticProfileFromEnrollment(cleaned);

      final appSupport = await getApplicationSupportDirectory();
      final embeddingPath =
          '${appSupport.path}/${SpeakerModelManifest.modelDirName}/${SpeakerModelManifest.embeddingFileName}';

      // Save augmented embedding
      await service.saveEmbeddingToFile(
          augmentedEmbedding.isEmpty ? embedding : augmentedEmbedding,
          embeddingPath);

      // Save acoustic profile as JSON
      final profilePath = '${appSupport.path}/${SpeakerModelManifest.modelDirName}/user_acoustic_profile.json';
      await File(profilePath).writeAsString(jsonEncode(profile.toJson()));
      SharedPreferencesUtil().acousticProfilePath = profilePath;
      debugPrint('[SpeechProfile] Acoustic profile saved: $profilePath');

      SharedPreferencesUtil().localSpeakerEmbeddingPath = embeddingPath;
      debugPrint('[SpeechProfile] Local speaker embedding saved');

      // Save enrollment audio as WAV for playback verification
      final wavPath =
          '${appSupport.path}/${SpeakerModelManifest.modelDirName}/enrollment_audio.wav';
      await _saveEnrollmentWav(pcm16, wavPath);
      SharedPreferencesUtil().saveString('speechProfileAudioPath', wavPath);
      debugPrint('[SpeechProfile] Enrollment audio saved: $wavPath');
    } finally {
      service.dispose();
    }
  }

  Float32List _computeAugmentedEmbedding(
      SpeakerEmbeddingService service, Float32List baseEmbedding, Float32List cleaned) {
    try {
      final embeddings = <Float32List>[baseEmbedding];

      // 6 augmentations for noise-robust embedding
      final augFns = [
        () => aug.addPinkNoise(cleaned),
        () => aug.addSimpleReverb(cleaned),
        () => aug.addBabbleNoise(cleaned),
        () => aug.addSpeedPerturbation(cleaned, speedFactor: 0.9),
        () => aug.addSpeedPerturbation(cleaned, speedFactor: 1.1),
        () => aug.addLowSnrNoise(cleaned),
      ];

      for (final fn in augFns) {
        final augmented = fn();
        final emb = service.extractEmbedding(augmented);
        if (emb.isNotEmpty) embeddings.add(emb);
      }

      if (embeddings.length < 2) return baseEmbedding;

      // Average all embeddings + L2 normalize
      final dim = baseEmbedding.length;
      final avg = Float32List(dim);
      for (final e in embeddings) {
        for (var i = 0; i < dim; i++) {
          avg[i] += e[i];
        }
      }
      for (var i = 0; i < dim; i++) {
        avg[i] /= embeddings.length;
      }

      debugPrint('[SpeechProfile] Augmented embedding from ${embeddings.length} samples');
      return audio.l2Normalize(avg);
    } catch (e) {
      debugPrint('[SpeechProfile] Augmentation failed, using base embedding: $e');
      return baseEmbedding;
    }
  }

  AcousticProfile _buildAcousticProfileFromEnrollment(Float32List cleaned) {
    final f0Stats = pitch.estimateF0Stats(cleaned);
    final energyDb = audio.computeRmsDb(cleaned);
    final spectralFeats = spectral.extractSpectralFeatures(cleaned);
    return AcousticProfile(
      f0Mean: f0Stats?.mean ?? 150.0,
      f0Std: f0Stats?.std ?? 40.0,
      energyDbMean: energyDb,
      spectralCentroid: spectralFeats?.centroid ?? 1500.0,
      spectralSlope: spectralFeats?.slope ?? 0.0,
    );
  }

  /// Save PCM16 enrollment audio as a WAV file for playback.
  Future<void> _saveEnrollmentWav(Uint8List pcm16, String path) async {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;
    final dataSize = pcm16.length;
    final fileSize = 36 + dataSize;

    final header = ByteData(44);
    // RIFF header
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, fileSize, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    // fmt chunk
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // (space)
    header.setUint32(16, 16, Endian.little); // chunk size
    header.setUint16(20, 1, Endian.little); // PCM format
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * numChannels * bitsPerSample ~/ 8, Endian.little);
    header.setUint16(32, numChannels * bitsPerSample ~/ 8, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data chunk
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataSize, Endian.little);

    final wav = Uint8List(44 + dataSize);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, 44 + dataSize, pcm16);

    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(wav, flush: true);
  }

  // TODO: use connection directly
  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return BleAudioCodec.pcm8;
    }
    return connection.getAudioCodec();
  }

  Future<StreamSubscription?> _getBleAudioBytesListener(
    String deviceId, {
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
  }

  Future<void> initiateFriendAudioStreaming() async {
    _bleBytesStream = await _getBleAudioBytesListener(
      device!.id,
      onAudioBytesReceived: (List<int> value) {
        if (value.isEmpty) return;
        audioStorage.storeFramePacket(value);

        value.removeRange(0, 3);
        if (_engine?.isConnected == true) {
          _engine?.pushAudio(Uint8List.fromList(value));
        }
      },
    );
  }

  _validateSingleSpeaker() {
    int speakersCount = segments.map((e) => e.speaker).toSet().length;
    debugPrint('_validateSingleSpeaker speakers count: $speakersCount');
    if (speakersCount > 1) {
      var speakerToWords = segments.fold<Map<int, int>>(
        {},
        (previousValue, element) {
          previousValue[element.speakerId] = (previousValue[element.speakerId] ?? 0) + element.text.split(' ').length;
          return previousValue;
        },
      );
      debugPrint('speakerToWords: $speakerToWords');
      if (speakerToWords.values.every((element) => element / segments.length > 0.08)) {
        notifyError('MULTIPLE_SPEAKERS');
      }
    }
  }

  void resetSegments() {
    segments.clear();
    streamStartedAtSecond = null;
    audioStorage.clearAudioBytes();
    text = '';
    percentageCompleted = 0;
    notifyListeners();
  }

  Future setupSpeechRecording() async {
    final permission = await getStoreRecordingPermission();
    permissionEnabled = permission;
    if (permission != null) {
      SharedPreferencesUtil().permissionStoreRecordingsEnabled = permission;
    }
    notifyListeners();
  }

  void updateProgressMessage() {
    text = segments.map((e) => e.text).join(' ').trim();
    int wordsCount = text.split(' ').length;
    message = 'Keep speaking until you get 100%.';
    if (wordsCount > 10) {
      message = 'Keep going, you are doing great';
    } else if (wordsCount > 25) {
      message = 'Great job, you are almost there';
    } else if (wordsCount > 40) {
      message = 'So close, just a little more';
    }
    notifyListeners();
  }

  Future close() async {
    connectionStateListener?.cancel();
    _bleBytesStream?.cancel();
    if (_usePhoneMic) {
      ServiceManager.instance().mic.stop();
      _usePhoneMic = false;
    }
    forceCompletionTimer?.cancel();
    segments.clear();
    text = '';
    startedRecording = false;
    percentageCompleted = 0;
    uploadingProfile = false;
    profileCompleted = false;
    await _engine?.disconnect();
    _engine = null;
    notifyListeners();
  }

  @override
  void dispose() {
    // This won't be called unless the provider is removed from the widget tree. So we need to manually call this in the widget's dispose method.
    connectionStateListener?.cancel();
    _bleBytesStream?.cancel();
    if (_usePhoneMic) {
      ServiceManager.instance().mic.stop();
    }
    forceCompletionTimer?.cancel();
    _finalizedCallback = null;
    _engine?.disconnect();
    _engine = null;
    ServiceManager.instance().device.unsubscribe(this);

    super.dispose();
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    switch (state) {
      case DeviceConnectionState.connected:
        var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
        if (connection == null) {
          return;
        }
        device = connection.device;
        notifyListeners();
        initiateFriendAudioStreaming();
        break;
      case DeviceConnectionState.disconnected:
        if (deviceId == device?.id) {
          device = null;
          notifyListeners();
        }
      default:
        debugPrint("Device connection state is not supported $state");
    }
  }

  @override
  void onDevices(List<BtDevice> devices) {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  void onClosed([int? closeCode]) {
    // Engine closed — nothing to do here.
  }

  void onError(Object err) {
    notifyError('WS_ERR');
  }

  void onSegmentReceived(List<TranscriptSegment> newSegments) {
    if (newSegments.isEmpty) return;
    if (segments.isEmpty) {
      audioStorage.removeFramesRange(fromSecond: 0, toSecond: newSegments[0].start.toInt());
    }
    streamStartedAtSecond ??= newSegments[0].start;

    var remainSegments = TranscriptSegment.updateSegments(segments, newSegments);
    TranscriptSegment.combineSegments(
      segments,
      remainSegments,
      toRemoveSeconds: streamStartedAtSecond ?? 0,
    );
    updateProgressMessage();
    _validateSingleSpeaker();
    _handleCompletion();
    notifyInfo('SCROLL_DOWN');
    debugPrint('Conversation creation timer restarted');
  }

  void onConnected() {}

  void onTerminalFailure(String reason) {
    debugPrint('[SpeechProfileProvider] Terminal failure: $reason');
  }
}
