import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/sockets/transcription_service.dart';
import 'package:omi/services/voice_profile_service.dart';
import 'package:omi/services/vad/vad_service.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/image/image_utils.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:permission_handler/permission_handler.dart';

/// Callback for sending audio bytes to the transcription socket.
typedef AudioByteSender = void Function(List<int> bytes);

/// Callback for voice command processing.
typedef VoiceCommandProcessor = Future<void> Function(
    List<List<int>> data, BleAudioCodec codec);

/// Handles audio routing from phone mic, BLE device, and system audio
/// to the transcription socket. Manages audio capture lifecycle, BLE
/// streaming metrics, speaker verification, and voice activity detection.
class AudioTransportService {
  // ---------------------------------------------------------------------------
  // Audio sources / device
  // ---------------------------------------------------------------------------

  BtDevice? _recordingDevice;
  BtDevice? get recordingDevice => _recordingDevice;

  StreamSubscription? _bleBytesStream;
  StreamSubscription? _blePhotoStream;
  StreamSubscription? _bleButtonStream;

  // ---------------------------------------------------------------------------
  // Desktop method channels
  // ---------------------------------------------------------------------------

  MethodChannel? _screenCaptureChannel;
  MethodChannel? _controlBarChannel;

  // ---------------------------------------------------------------------------
  // Audio levels (desktop)
  // ---------------------------------------------------------------------------

  String? microphoneName;
  double microphoneLevel = 0.0;
  double systemAudioLevel = 0.0;

  // ---------------------------------------------------------------------------
  // Auto-reconnect (desktop microphone device change)
  // ---------------------------------------------------------------------------

  bool _isAutoReconnecting = false;
  bool get isAutoReconnecting => _isAutoReconnecting;
  Timer? _reconnectTimer;
  int _reconnectCountdown = 5;
  int get reconnectCountdown => _reconnectCountdown;

  // ---------------------------------------------------------------------------
  // BLE streaming metrics
  // ---------------------------------------------------------------------------

  int _blesBytesReceived = 0;
  int _wsSocketBytesSent = 0;
  double _bleReceiveRateKbps = 0.0;
  double _wsSendRateKbps = 0.0;
  DateTime? _metricsLastCalculated;
  Timer? _metricsTimer;
  int _metricsLogCounter = 0;
  double get bleReceiveRateKbps => _bleReceiveRateKbps;
  double get wsSendRateKbps => _wsSendRateKbps;

  // ---------------------------------------------------------------------------
  // Audio buffer for speaker verification
  // ---------------------------------------------------------------------------

  WavBytesUtil? _audioBuffer;

  // ---------------------------------------------------------------------------
  // System audio buffer (desktop)
  // ---------------------------------------------------------------------------

  List<int> _systemAudioBuffer = [];
  bool _systemAudioCaching = true;

  /// ~5 seconds at 16 kHz PCM16 mono (16000 samples/s * 2 bytes * 5s).
  static const int _maxAudioBufferBytes = 160000;

  // ---------------------------------------------------------------------------
  // Voice commands (BLE button)
  // ---------------------------------------------------------------------------

  DateTime? _voiceCommandSession;
  List<List<int>> _commandBytes = [];
  bool _isProcessingButtonEvent = false;
  Timer? _voiceCommandTimer;

  // ---------------------------------------------------------------------------
  // Audio tracking
  // ---------------------------------------------------------------------------

  int _audioBytesSent = 0;
  DateTime? _lastAudioBytesSentAt;
  DateTime? get lastAudioBytesSentAt => _lastAudioBytesSentAt;

  // ---------------------------------------------------------------------------
  // WAL support
  // ---------------------------------------------------------------------------

  bool _isWalSupported = false;
  bool get isWalSupported => _isWalSupported;

  // ---------------------------------------------------------------------------
  // Photos from device
  // ---------------------------------------------------------------------------

  List<ConversationPhoto> photos = [];

  // ---------------------------------------------------------------------------
  // External references (set by owner, e.g. CaptureProvider)
  // ---------------------------------------------------------------------------

  AudioByteSender? _socketSender;
  VoiceCommandProcessor? _voiceCommandProcessor;
  VoidCallback? _onNotifyListeners;
  VadService? _vadService;

  // ---------------------------------------------------------------------------
  // Recording timer (desktop control-bar duration)
  // ---------------------------------------------------------------------------

  Timer? _recordingTimer;
  int _recordingDuration = 0;
  int get recordingDuration => _recordingDuration;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  CaptureLogService get _captureLog => CaptureLogService.instance;
  IWalService get _wal => ServiceManager.instance().wal;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Set up desktop method channels. Call once from CaptureProvider constructor.
  void initialize() {
    if (PlatformService.isDesktop) {
      _screenCaptureChannel = const MethodChannel('screenCapturePlatform');
      _controlBarChannel = const MethodChannel('com.omi/floating_control_bar');
      _controlBarChannel!.setMethodCallHandler(_handleFloatingControlBarMethodCall);
    }
  }

  // ---------------------------------------------------------------------------
  // External dependency injection
  // ---------------------------------------------------------------------------

  void setSocketSender(AudioByteSender? sender) {
    _socketSender = sender;
  }

  void setVadService(VadService? vad) {
    _vadService = vad;
  }

  void setVoiceCommandProcessor(VoiceCommandProcessor? processor) {
    _voiceCommandProcessor = processor;
  }

  void setNotifyListenersCallback(VoidCallback? callback) {
    _onNotifyListeners = callback;
  }

  // ---------------------------------------------------------------------------
  // Device management
  // ---------------------------------------------------------------------------

  void updateRecordingDevice(BtDevice? device) {
    debugPrint('[AudioTransport] Device changed: ${_recordingDevice?.id} -> ${device?.id}');
    _recordingDevice = device;
    _onNotifyListeners?.call();
  }

  // ---------------------------------------------------------------------------
  // Phone mic recording
  // ---------------------------------------------------------------------------

  /// Starts the phone microphone recording via the background service.
  /// [onStateChange] is called when the recording state transitions.
  /// [socketState] provides the current socket connection state.
  Future<void> startPhoneMicRecording({
    required Function(RecordingState) onStateChange,
    required SocketServiceState Function() socketState,
  }) async {
    onStateChange(RecordingState.initialising);
    await Permission.microphone.request();

    _audioBytesSent = 0;
    await ServiceManager.instance().mic.start(
      onByteReceived: (Uint8List bytes) {
        _lastAudioBytesSentAt = DateTime.now();
        // Always send audio to pipeline — it handles buffering during reconnect.
        // VAD only runs when socket is connected (Deepgram requires live connection).
        if (_vadService != null &&
            _vadService!.isInitialized &&
            socketState() == SocketServiceState.connected) {
          _vadService!.processAudioFrame(bytes);
        } else {
          _socketSender?.call(bytes);
        }
        _audioBytesSent += bytes.length;
      },
      onRecording: () {
        onStateChange(RecordingState.record);
      },
      onStop: () {
        onStateChange(RecordingState.stop);
      },
      onInitializing: () {
        onStateChange(RecordingState.initialising);
      },
    );
  }

  /// Stops the phone microphone recording.
  /// Bug fix H3: properly awaits mic.stop() before any callbacks fire.
  Future<void> stopPhoneMicRecording() async {
    // ServiceManager.mic.stop() is synchronous for BackgroundService variant
    // but we wrap in try/catch to be safe
    try {
      ServiceManager.instance().mic.stop();
    } catch (e) {
      debugPrint('[AudioTransport] Error stopping mic: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // BLE device recording
  // ---------------------------------------------------------------------------

  /// Starts audio and (optionally) photo streaming from the connected BLE device.
  Future<void> startDeviceAudioStreaming() async {
    final device = _recordingDevice;
    if (device == null || device.id.isEmpty) return;

    final deviceId = device.id;
    final connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return;

    final codec = await _getAudioCodec(deviceId);
    await _wal.getSyncs().phone.onAudioCodecChanged(codec);

    // Set device info for WAL creation
    final pd = await device.getDeviceInfo(connection);
    final deviceModel = pd.modelNumber.isNotEmpty ? pd.modelNumber : 'Maity';
    _wal.getSyncs().phone.setDeviceInfo(deviceId, deviceModel);

    // Initialize audio buffer for speaker verification
    _audioBuffer = WavBytesUtil(codec: codec, framesPerSecond: 50);
    debugPrint('[AudioTransport] Audio buffer initialized for speaker verification');

    await streamButton(deviceId);
    await streamAudioToWs(deviceId, codec);

    // Start photo streaming if supported
    if (await connection.hasPhotoStreamingCharacteristic()) {
      await _initiateDevicePhotoStreaming();
    }
  }

  /// Stops BLE device audio (and photo) streaming.
  Future<void> stopDeviceAudioStreaming({bool cleanDevice = false}) async {
    await closeBleStream();
    if (cleanDevice) {
      _recordingDevice = null;
    }
  }

  /// Streams audio bytes from BLE device to websocket.
  Future<void> streamAudioToWs(String deviceId, BleAudioCodec codec) async {
    debugPrint('[AudioTransport] streamAudioToWs device=$deviceId codec=${codec.name}');
    _captureLog.log('ble', 'audio_stream_started', details: {
      'device_id': deviceId,
      'codec': codec.name,
    });
    _bleBytesStream?.cancel();
    startMetricsTracking();

    _bleBytesStream = await _getBleAudioBytesListener(
      deviceId,
      onAudioBytesReceived: (List<int> value) {
        // Fix H1: BLE transport may reuse buffers — one defensive copy with
        // Uint8List.fromList is cheaper than List<int>.from (typed, no boxing).
        if (value.length < 3) return;
        final Uint8List snapshot = Uint8List.fromList(value);

        // Track bytes received from BLE
        _blesBytesReceived += snapshot.length;
        _lastAudioBytesSentAt = DateTime.now();

        // Store audio for speaker verification
        _audioBuffer?.storeFramePacket(snapshot);

        // Command button triggered
        bool voiceCommandSupported =
            _recordingDevice != null && _recordingDevice!.type == DeviceType.omi;
        if (_voiceCommandSession != null && voiceCommandSupported) {
          _commandBytes.add(snapshot.sublist(3));
        }

        // Local storage syncs (WAL)
        var checkWalSupported = (_recordingDevice?.type == DeviceType.omi) &&
            codec.isOpusSupported() &&
            (_socketSender == null ||
                SharedPreferencesUtil().unlimitedLocalStorageEnabled);
        if (checkWalSupported != _isWalSupported) {
          _isWalSupported = checkWalSupported;
          // UI updates via _calculateMetricsRates() every 5s — sufficient for WAL indicator
        }
        // Send to websocket — sublist on Uint8List returns a view, no copy.
        if (_socketSender != null) {
          final paddingLeft =
              (_recordingDevice?.type == DeviceType.omi) ? 3 : 0;
          final trimmedValue =
              paddingLeft > 0 ? snapshot.sublist(paddingLeft) : snapshot;
          _socketSender!.call(trimmedValue);

          _wsSocketBytesSent += trimmedValue.length;
        } else if (_isWalSupported) {
          // WAL only when audio does NOT go through sendToSocket (which has its own WAL)
          _wal.getSyncs().phone.onByteStream(snapshot);
        }
      },
    );
    _onNotifyListeners?.call();
  }

  /// Streams button events from BLE device for double-tap and voice commands.
  Future<void> streamButton(String deviceId) async {
    debugPrint('[AudioTransport] streamButton device=$deviceId');
    _bleButtonStream?.cancel();
    _bleButtonStream = await _getBleButtonListener(
      deviceId,
      onButtonReceived: (List<int> value) {
        if (value.length < 4) return;
        // Button events are infrequent — typed copy is fine here
        final snapshot = Uint8List.fromList(value);

        var buttonState = ByteData.view(
          Uint8List.fromList(snapshot.sublist(0, 4).reversed.toList()).buffer,
        ).getUint32(0);
        debugPrint('[AudioTransport] Device button state: $buttonState');

        // Double tap
        if (buttonState == 2) {
          if (_isProcessingButtonEvent) return;

          if (SharedPreferencesUtil().doubleTapPausesMuting) {
            _isProcessingButtonEvent = true;
            // Pause/resume is handled externally by CaptureProvider
            // via onDoubleTap callback - for now just set the flag
            _isProcessingButtonEvent = false;
          }
          return;
        }

        // Start long press (voice commands)
        if (buttonState == 3 && _voiceCommandSession == null) {
          _voiceCommandSession = DateTime.now();
          _commandBytes = [];
          _watchVoiceCommands(deviceId, _voiceCommandSession!);
          _playSpeakerHaptic(deviceId, 1);
        }

        // Release (end voice command)
        if (buttonState == 5 && _voiceCommandSession != null) {
          _voiceCommandSession = null;
          var data = List<List<int>>.from(_commandBytes);
          _commandBytes = [];
          _processVoiceCommandBytes(deviceId, data);
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // System audio recording (desktop)
  // ---------------------------------------------------------------------------

  /// Starts system audio recording on desktop (macOS/Windows).
  Future<void> startSystemAudioRecording({
    required Function(RecordingState) onStateChange,
    required SocketServiceState Function() socketState,
  }) async {
    if (!PlatformService.isDesktop) return;

    onStateChange(RecordingState.initialising);

    _systemAudioBuffer = [];
    _systemAudioCaching = true;
    Future.delayed(const Duration(seconds: 3), () {
      _systemAudioCaching = false;
      _flushSystemAudioBuffer(socketState);
    });

    bool permissionsGranted = await _checkAndRequestSystemAudioPermissions();
    if (!permissionsGranted) {
      onStateChange(RecordingState.stop);
      return;
    }

    await ServiceManager.instance().systemAudio.start(
      onFormatReceived: (Map<String, dynamic> format) async {
        // Information only
      },
      onByteReceived: (Uint8List bytes) {
        _processSystemAudioByteReceived(bytes, socketState);
      },
      onRecording: () {
        onStateChange(RecordingState.systemAudioRecord);
        _startRecordingTimer();
      },
      onStop: () {
        onStateChange(RecordingState.stop);
      },
      onError: (error) {
        debugPrint('[AudioTransport] System audio error: $error');
        onStateChange(RecordingState.stop);
      },
      onSystemWillSleep: (wasRecording) {
        debugPrint('[AudioTransport] System will sleep, was recording: $wasRecording');
      },
      onSystemDidWake: (nativeIsRecording) async {
        debugPrint('[AudioTransport] System wake, native recording: $nativeIsRecording');
      },
      onScreenDidLock: (wasRecording) {
        debugPrint('[AudioTransport] Screen locked, was recording: $wasRecording');
      },
      onScreenDidUnlock: () {
        debugPrint('[AudioTransport] Screen unlocked');
      },
      onDisplaySetupInvalid: (reason) {
        debugPrint('[AudioTransport] Display invalid: $reason');
        onStateChange(RecordingState.stop);
      },
      onMicrophoneDeviceChanged: () => _onMicrophoneDeviceChanged(),
      onMicrophoneStatus: _onMicrophoneStatus,
    );
  }

  /// Stops system audio recording.
  Future<void> stopSystemAudioRecording() async {
    if (!PlatformService.isDesktop) return;

    _isAutoReconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    ServiceManager.instance().systemAudio.stop();
    _stopRecordingTimer();
  }

  /// Pauses system audio recording (stops native capture, keeps state).
  Future<void> pauseSystemAudioRecording({bool isAuto = false}) async {
    if (!PlatformService.isDesktop) return;

    if (!isAuto) {
      _isAutoReconnecting = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }

    ServiceManager.instance().systemAudio.stop();
    _onNotifyListeners?.call();
  }

  /// Resumes system audio recording after pause.
  Future<void> resumeSystemAudioRecording({
    required Function(RecordingState) onStateChange,
    required SocketServiceState Function() socketState,
  }) async {
    if (!PlatformService.isDesktop) return;
    await startSystemAudioRecording(
      onStateChange: onStateChange,
      socketState: socketState,
    );
  }

  // ---------------------------------------------------------------------------
  // Speaker verification
  // ---------------------------------------------------------------------------

  /// Verifies speakers using voice embeddings and re-labels is_user in segments.
  /// Uses the audio buffer stored during recording to extract audio for each speaker.
  Future<void> verifySpeakersWithVoiceProfile(
    String userId,
    List<TranscriptSegment> segments,
  ) async {
    final status = await VoiceProfileService.getProfileStatus(userId);
    if (!status.hasProfile) {
      debugPrint('[AudioTransport] No voice profile found, using default speaker assignment');
      return;
    }

    debugPrint('[AudioTransport] Voice profile found, created: ${status.createdAt}');

    if (_audioBuffer == null || !_audioBuffer!.hasFrames()) {
      debugPrint('[AudioTransport] No audio buffer available for speaker verification');
      return;
    }

    debugPrint('[AudioTransport] Audio buffer: ${_audioBuffer!.durationSeconds.toStringAsFixed(1)}s');

    // Get unique speaker IDs
    final speakerIds = segments.map((s) => s.speakerId).toSet();
    debugPrint('[AudioTransport] Found ${speakerIds.length} unique speakers: $speakerIds');

    if (speakerIds.length <= 1) {
      debugPrint('[AudioTransport] Only one speaker, skipping verification');
      return;
    }

    // Group segments by speaker
    final speakerSegments = <int, List<TranscriptSegment>>{};
    for (var seg in segments) {
      speakerSegments.putIfAbsent(seg.speakerId, () => []).add(seg);
    }

    // Extract audio for each speaker (longest segment for best accuracy)
    final speakerAudioSegments = <int, Uint8List>{};
    for (var entry in speakerSegments.entries) {
      final sortedSegments = List<TranscriptSegment>.from(entry.value)
        ..sort((a, b) => (b.end - b.start).compareTo(a.end - a.start));

      final longest = sortedSegments.first;
      final duration = longest.end - longest.start;

      if (duration < 1.0) {
        debugPrint('[AudioTransport] Speaker ${entry.key} too short (${duration.toStringAsFixed(1)}s), skipping');
        continue;
      }

      final audioBytes = _audioBuffer!.extractAudioRange(longest.start, longest.end);
      if (audioBytes != null) {
        speakerAudioSegments[entry.key] = audioBytes;
        debugPrint('[AudioTransport] Speaker ${entry.key}: ${duration.toStringAsFixed(1)}s, ${audioBytes.length} bytes');
      } else {
        debugPrint('[AudioTransport] Failed to extract audio for speaker ${entry.key}');
      }
    }

    if (speakerAudioSegments.isEmpty) {
      debugPrint('[AudioTransport] No valid speaker audio, keeping default assignment');
      return;
    }

    try {
      debugPrint('[AudioTransport] Verifying ${speakerAudioSegments.length} speakers');
      final results = await VoiceProfileService.verifySpeakers(
        userId: userId,
        speakerAudioSegments: speakerAudioSegments,
        threshold: 0.75,
      );

      debugPrint('[AudioTransport] Verification results: $results');

      int updatedCount = 0;
      for (var seg in segments) {
        final result = results[seg.speakerId.toString()];
        if (result != null) {
          final wasUser = seg.isUser;
          seg.isUser = result.isUser;
          if (wasUser != seg.isUser) updatedCount++;
        }
      }

      debugPrint('[AudioTransport] Updated is_user for $updatedCount segments');
    } catch (e) {
      debugPrint('[AudioTransport] Speaker verification failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Metrics
  // ---------------------------------------------------------------------------

  void startMetricsTracking() {
    _blesBytesReceived = 0;
    _wsSocketBytesSent = 0;
    _bleReceiveRateKbps = 0.0;
    _wsSendRateKbps = 0.0;
    _metricsLastCalculated = DateTime.now();

    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _calculateMetricsRates();
    });
  }

  void stopMetricsTracking() {
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _blesBytesReceived = 0;
    _wsSocketBytesSent = 0;
    _bleReceiveRateKbps = 0.0;
    _wsSendRateKbps = 0.0;
    _metricsLastCalculated = null;
    _onNotifyListeners?.call();
  }

  void _calculateMetricsRates() {
    final now = DateTime.now();
    if (_metricsLastCalculated == null) {
      _metricsLastCalculated = now;
      return;
    }

    final elapsedSeconds =
        now.difference(_metricsLastCalculated!).inMilliseconds / 1000.0;
    if (elapsedSeconds > 0) {
      final newBleRate = (_blesBytesReceived * 8) / (elapsedSeconds * 1000);
      final newWsRate = (_wsSocketBytesSent * 8) / (elapsedSeconds * 1000);
      final rateChanged = (newBleRate - _bleReceiveRateKbps).abs() > 0.1 ||
          (newWsRate - _wsSendRateKbps).abs() > 0.1;

      _bleReceiveRateKbps = newBleRate;
      _wsSendRateKbps = newWsRate;

      _metricsLogCounter++;
      if (_metricsLogCounter >= 6) {
        _metricsLogCounter = 0;
        _captureLog.log('metrics', 'metrics_snapshot', severity: 'debug', details: {
          'ble_kbps': double.parse(_bleReceiveRateKbps.toStringAsFixed(2)),
          'ws_kbps': double.parse(_wsSendRateKbps.toStringAsFixed(2)),
          'audio_bytes_sent': _audioBytesSent,
        });
      }

      _blesBytesReceived = 0;
      _wsSocketBytesSent = 0;
      _metricsLastCalculated = now;

      if (rateChanged) {
        _onNotifyListeners?.call();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // BLE stream cleanup
  // ---------------------------------------------------------------------------

  /// Closes BLE audio, photo, and button streams, stops metrics, and stops
  /// photo controller on device if applicable.
  Future<void> closeBleStream() async {
    _captureLog.log('ble', 'audio_stream_closed');
    await _bleBytesStream?.cancel();
    _bleBytesStream = null;
    await _blePhotoStream?.cancel();
    _blePhotoStream = null;
    _bleButtonStream?.cancel();
    _bleButtonStream = null;
    _voiceCommandTimer?.cancel();
    _voiceCommandTimer = null;
    stopMetricsTracking();

    if (_recordingDevice != null) {
      var connection = await ServiceManager.instance()
          .device
          .ensureConnection(_recordingDevice!.id);
      if (connection != null &&
          await connection.hasPhotoStreamingCharacteristic()) {
        await connection.performCameraStopPhotoController();
      }
    }
    _onNotifyListeners?.call();
  }

  // ---------------------------------------------------------------------------
  // Cleanup / dispose
  // ---------------------------------------------------------------------------

  /// Clears audio buffer used for speaker verification.
  void clearAudioBuffer() {
    _audioBuffer?.clearAudioBytes();
    _audioBuffer = null;
  }

  void dispose() {
    _bleBytesStream?.cancel();
    _blePhotoStream?.cancel();
    _bleButtonStream?.cancel();
    _metricsTimer?.cancel();
    _reconnectTimer?.cancel();
    _recordingTimer?.cancel();
    _voiceCommandTimer?.cancel();
    _voiceCommandTimer = null;
    _audioBuffer = null;
  }

  // ===========================================================================
  // Private helpers
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // BLE helpers
  // ---------------------------------------------------------------------------

  Future<BleAudioCodec> _getAudioCodec(String deviceId) async {
    var connection =
        await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return BleAudioCodec.pcm8;
    return connection.getAudioCodec();
  }

  Future<bool> _playSpeakerHaptic(String deviceId, int level) async {
    var connection =
        await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return false;
    return connection.performPlayToSpeakerHaptic(level);
  }

  Future<StreamSubscription?> _getBleAudioBytesListener(
    String deviceId, {
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    var connection =
        await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return null;
    return connection.getBleAudioBytesListener(
        onAudioBytesReceived: onAudioBytesReceived);
  }

  Future<StreamSubscription?> _getBleButtonListener(
    String deviceId, {
    required void Function(List<int>) onButtonReceived,
  }) async {
    var connection =
        await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return null;
    return connection.getBleButtonListener(onButtonReceived: onButtonReceived);
  }

  Future<List<int>> _getBleButtonState(String deviceId) async {
    var connection =
        await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return <int>[];
    return connection.getBleButtonState();
  }

  // ---------------------------------------------------------------------------
  // Voice commands
  // ---------------------------------------------------------------------------

  void _processVoiceCommandBytes(String deviceId, List<List<int>> data) async {
    if (data.isEmpty) {
      debugPrint('[AudioTransport] Voice frames empty');
      return;
    }
    if (_voiceCommandProcessor == null) return;

    BleAudioCodec codec = await _getAudioCodec(_recordingDevice!.id);
    await _voiceCommandProcessor!(data, codec);
  }

  void _watchVoiceCommands(String deviceId, DateTime session) {
    _voiceCommandTimer?.cancel();
    _voiceCommandTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      if (session != _voiceCommandSession) {
        t.cancel();
        return;
      }
      if (_recordingDevice == null) {
        t.cancel();
        return;
      }
      var value = await _getBleButtonState(deviceId);
      if (value.isEmpty || value.length < 4) return;
      var buttonState = ByteData.view(
        Uint8List.fromList(value.sublist(0, 4).reversed.toList()).buffer,
      ).getUint32(0);

      if (buttonState == 5 && session == _voiceCommandSession) {
        _voiceCommandSession = null;
        var data = List<List<int>>.from(_commandBytes);
        _commandBytes = [];
        _processVoiceCommandBytes(deviceId, data);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Photo streaming
  // ---------------------------------------------------------------------------

  Future<void> _initiateDevicePhotoStreaming() async {
    if (_recordingDevice == null) return;
    final deviceId = _recordingDevice!.id;
    var connection =
        await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return;

    await connection.performCameraStartPhotoController();
    _blePhotoStream = await connection.performGetImageListener(
      onImageReceived: (orientedImage) async {
        final rotatedImageBytes = rotateImage(orientedImage);
        final String tempId = 'temp_img_${DateTime.now().millisecondsSinceEpoch}';
        final String base64Image = base64Encode(rotatedImageBytes);

        photos.add(ConversationPhoto(
          id: tempId,
          base64: base64Image,
          createdAt: DateTime.now(),
        ));
        photos = List.from(photos);
        _onNotifyListeners?.call();

        // Chunked upload via socket
        const int chunkSize = 8192;
        final totalChunks = (base64Image.length / chunkSize).ceil();

        for (int i = 0; i < totalChunks; i++) {
          final start = i * chunkSize;
          final end = (start + chunkSize > base64Image.length)
              ? base64Image.length
              : start + chunkSize;
          final chunk = base64Image.substring(start, end);

          final payload = jsonEncode({
            'type': 'image_chunk',
            'id': tempId,
            'index': i,
            'total': totalChunks,
            'data': chunk,
          });

          _socketSender?.call(payload.codeUnits);
          await Future.delayed(const Duration(milliseconds: 20));
        }
      },
    );
    _onNotifyListeners?.call();
  }

  // ---------------------------------------------------------------------------
  // System audio helpers
  // ---------------------------------------------------------------------------

  void _processSystemAudioByteReceived(
    Uint8List bytes,
    SocketServiceState Function() socketState,
  ) {
    _systemAudioBuffer.addAll(bytes);

    // Enforce max buffer size to prevent unbounded growth
    if (_systemAudioBuffer.length > _maxAudioBufferBytes) {
      _systemAudioBuffer = _systemAudioBuffer
          .sublist(_systemAudioBuffer.length - _maxAudioBufferBytes);
    }

    if (!_systemAudioCaching) {
      _flushSystemAudioBuffer(socketState);
    }
  }

  void _flushSystemAudioBuffer(SocketServiceState Function() socketState) {
    if (socketState() != SocketServiceState.connected) return;

    // VAD expects 512 samples (1024 bytes) at 16kHz
    const frameSize = 1024;
    while (_systemAudioBuffer.length >= frameSize) {
      final chunk = _systemAudioBuffer.sublist(0, frameSize);

      if (_vadService != null && _vadService!.isInitialized) {
        _vadService!.processAudioFrame(Uint8List.fromList(chunk));
      } else {
        _socketSender?.call(chunk);
      }

      _systemAudioBuffer.removeRange(0, frameSize);
    }
  }

  /// Bug fix M2: MethodChannel invocation with 10-second timeout.
  Future<T?> _invokeMethodWithTimeout<T>(
    MethodChannel channel,
    String method, [
    dynamic arguments,
  ]) async {
    try {
      return await channel
          .invokeMethod<T>(method, arguments)
          .timeout(const Duration(seconds: 10), onTimeout: () {
        debugPrint('[AudioTransport] MethodChannel timeout: $method');
        return null;
      });
    } catch (e) {
      debugPrint('[AudioTransport] MethodChannel error: $method - $e');
      return null;
    }
  }

  Future<bool> _checkAndRequestSystemAudioPermissions() async {
    if (_screenCaptureChannel == null) return false;

    final micStatus = await _invokeMethodWithTimeout<String>(
        _screenCaptureChannel!, 'checkMicrophonePermission');

    if (micStatus != 'granted') {
      if (micStatus == 'undetermined' || micStatus == 'unavailable') {
        final granted = await _invokeMethodWithTimeout<bool>(
            _screenCaptureChannel!, 'requestMicrophonePermission');
        if (granted != true) {
          debugPrint('[AudioTransport] Microphone permission denied');
          return false;
        }
      } else if (micStatus == 'denied') {
        debugPrint('[AudioTransport] Microphone permission denied in system prefs');
        return false;
      }
    }

    final screenStatus = await _invokeMethodWithTimeout<String>(
        _screenCaptureChannel!, 'checkScreenCapturePermission');

    if (screenStatus != 'granted') {
      final granted = await _invokeMethodWithTimeout<bool>(
          _screenCaptureChannel!, 'requestScreenCapturePermission');
      if (granted != true) {
        debugPrint('[AudioTransport] Screen capture permission denied');
        return false;
      }
    }
    return true;
  }

  Future<void> _onMicrophoneDeviceChanged() async {
    if (_screenCaptureChannel == null) return;

    final nativeRecording = await _invokeMethodWithTimeout<bool>(
            _screenCaptureChannel!, 'isRecording') ??
        false;
    if (!nativeRecording) return;

    _isAutoReconnecting = true;
    _reconnectCountdown = 5;
    _onNotifyListeners?.call();

    await pauseSystemAudioRecording(isAuto: true);

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_reconnectCountdown > 1) {
        _reconnectCountdown--;
        _onNotifyListeners?.call();
      } else {
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _isAutoReconnecting = false;
        _onNotifyListeners?.call();
        // Resume is orchestrated by the owner (CaptureProvider)
      }
    });
  }

  void _onMicrophoneStatus(
    String deviceName,
    double micLevel,
    double sysAudioLevel,
  ) {
    final bool needsUpdate = microphoneName != deviceName ||
        (microphoneLevel - micLevel).abs() > 0.05 ||
        (systemAudioLevel - sysAudioLevel).abs() > 0.05;

    if (needsUpdate) {
      microphoneName = deviceName;
      microphoneLevel = micLevel;
      systemAudioLevel = sysAudioLevel;
      _onNotifyListeners?.call();
    }
  }

  // ---------------------------------------------------------------------------
  // Desktop floating control bar
  // ---------------------------------------------------------------------------

  /// Callback used by CaptureProvider to toggle pause/resume via control bar.
  /// The actual pause/resume logic is delegated to callbacks since AudioTransport
  /// does not own the recording state machine.
  VoidCallback? onTogglePauseResume;

  Future<void> _handleFloatingControlBarMethodCall(MethodCall call) async {
    if (!PlatformService.isDesktop) return;

    switch (call.method) {
      case 'togglePauseResume':
        onTogglePauseResume?.call();
        break;
      default:
        Logger.debug(
            'FloatingControlBarChannel: Unhandled method ${call.method}');
    }
  }

  // ---------------------------------------------------------------------------
  // Recording timer (desktop duration broadcast)
  // ---------------------------------------------------------------------------

  void _startRecordingTimer() {
    _recordingDuration = 0;
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _recordingDuration++;
    });
  }

  void _stopRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingDuration = 0;
  }

  // ---------------------------------------------------------------------------
  // Accessors for testing
  // ---------------------------------------------------------------------------

  @visibleForTesting
  List<int> get systemAudioBuffer => _systemAudioBuffer;

  @visibleForTesting
  int get audioBytesSent => _audioBytesSent;

  @visibleForTesting
  WavBytesUtil? get audioBuffer => _audioBuffer;
}
