import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/services/local_stt/local_stt_model_type.dart';
import 'package:omi/services/local_stt/local_stt_socket.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/services/sockets/pure_socket.dart';
import 'package:omi/services/sockets/transcription_service.dart';
import 'package:omi/utils/debug_log_manager.dart';

export 'package:omi/utils/audio/audio_transcoder.dart';
export 'package:omi/services/sockets/composite_transcription_socket.dart';
export 'package:omi/services/sockets/pure_polling.dart';
export 'package:omi/services/sockets/pure_streaming_stt.dart';
export 'package:omi/models/stt_response_schema.dart';
export 'package:omi/models/stt_result.dart';
export 'package:omi/services/sockets/transcription_polling_service.dart';

abstract interface class ITransctiptSegmentSocketServiceListener {
  void onMessageEventReceived(MessageEvent event);

  void onSegmentReceived(List<TranscriptSegment> segments);

  void onError(Object err);

  void onConnected();

  void onClosed([int? closeCode]);

  void onTerminalFailure(String reason);
}

/// Optional mixin for listeners that want to receive live preview text
/// from local STT. Listeners that don't implement this are simply skipped.
mixin ILocalSttPreviewListener {
  void onPreviewTextReceived(String? text);
}

class SpeechProfileTranscriptSegmentSocketService extends TranscriptSegmentSocketService {
  SpeechProfileTranscriptSegmentSocketService.create(super.sampleRate, super.codec, super.language,
      {super.source, super.customSttMode})
      : super.create(includeSpeechProfile: false);
}

class ConversationTranscriptSegmentSocketService extends TranscriptSegmentSocketService {
  ConversationTranscriptSegmentSocketService.create(super.sampleRate, super.codec, super.language,
      {super.source, super.customSttMode})
      : super.create(includeSpeechProfile: true);
}

class CustomSttTranscriptSegmentSocketService extends TranscriptSegmentSocketService {
  CustomSttTranscriptSegmentSocketService.create(super.sampleRate, super.codec, super.language, {super.source})
      : super.create(includeSpeechProfile: true, customSttMode: true);
}

enum SocketServiceState {
  connected,
  disconnected,
}

class TranscriptSegmentSocketService implements IPureSocketListener {
  late IPureSocket _socket;
  final Map<Object, ITransctiptSegmentSocketServiceListener> _listeners = {};

  /// Access to the underlying socket (for composite service creation)
  IPureSocket get socket => _socket;

  SocketServiceState get state =>
      _socket.status == PureSocketStatus.connected ? SocketServiceState.connected : SocketServiceState.disconnected;

  int sampleRate;
  BleAudioCodec codec;
  String language;
  bool includeSpeechProfile;
  String? source;
  bool customSttMode;
  String? sttConfigId;

  TranscriptSegmentSocketService.create(
    this.sampleRate,
    this.codec,
    this.language, {
    this.includeSpeechProfile = false,
    this.source,
    this.customSttMode = false,
    this.sttConfigId,
  }) {
    var params = '?language=$language&sample_rate=$sampleRate&codec=$codec&uid=${SharedPreferencesUtil().uid}'
        '&include_speech_profile=$includeSpeechProfile&stt_service=${SharedPreferencesUtil().transcriptionModel}'
        '&conversation_timeout=${SharedPreferencesUtil().conversationSilenceDuration}';

    if (source != null && source!.isNotEmpty) {
      params += '&source=${Uri.encodeComponent(source!)}';
    }

    if (customSttMode) {
      params += '&custom_stt=enabled';
    }

    String url =
        '${Env.apiBaseUrl!.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://')}v4/listen$params';

    _socket = PureSocket(url);
    _socket.setListener(this);
  }

  TranscriptSegmentSocketService.withSocket(
    this.sampleRate,
    this.codec,
    this.language,
    IPureSocket socket, {
    this.includeSpeechProfile = false,
    this.source,
    this.customSttMode = false,
    this.sttConfigId,
  }) {
    _socket = socket;
    _socket.setListener(this);
  }

  void subscribe(Object context, ITransctiptSegmentSocketServiceListener listener) {
    _listeners.remove(context.hashCode);
    _listeners.putIfAbsent(context.hashCode, () => listener);
  }

  void unsubscribe(Object context) {
    _listeners.remove(context.hashCode);
  }

  /// Forward live preview text from local STT to listeners that support it.
  void notifyPreview(String? text) {
    for (final listener in _listeners.values) {
      if (listener is ILocalSttPreviewListener) {
        (listener as ILocalSttPreviewListener).onPreviewTextReceived(text);
      }
    }
  }

  Future start() async {
    bool ok = await _socket.connect();
    if (!ok) {
      CaptureLogService.instance.log('socket', 'socket_connect_failed', severity: 'error', details: {
        'sample_rate': sampleRate,
        'codec': codec.toString(),
        'language': language,
        'custom_stt': customSttMode,
      });
      debugPrint("Can not connect to websocket");
      await DebugLogManager.logWarning('transcription_socket_connect_failed', {
        'url': Env.apiBaseUrl?.replaceAll('https', 'wss') ?? 'null',
        'sample_rate': sampleRate,
        'codec': codec.toString(),
        'language': language,
      });
    }
  }

  Future stop({String? reason}) async {
    await _socket.stop();
    _listeners.clear();

    if (reason != null) {
      debugPrint(reason);
      await DebugLogManager.logInfo('transcription_socket_stopped', {'reason': reason});
    }
  }

  Future send(dynamic message) async {
    _socket.send(message);
    return;
  }

  @override
  void onClosed([int? closeCode]) {
    _listeners.forEach((k, v) {
      v.onClosed(closeCode);
    });
    DebugLogManager.logEvent('transcription_socket_closed', {
      'close_code': closeCode ?? -1,
    });
  }

  @override
  void onError(Object err, StackTrace trace) {
    _listeners.forEach((k, v) {
      v.onError(err);
    });
    DebugLogManager.logError(err, trace, 'transcription_socket_error');
  }

  @override
  void onMessage(event) {
    // Decode json
    dynamic jsonEvent;
    try {
      jsonEvent = jsonDecode(event);
    } on FormatException catch (e) {
      debugPrint(e.toString());
      DebugLogManager.logWarning('transcription_socket_parse_error', {'error': e.toString()});
    }
    if (jsonEvent == null) {
      debugPrint("Can not decode message event json $event");
      return;
    }

    // Transcript segments
    if (jsonEvent is List) {
      var segments = jsonEvent;
      if (segments.isEmpty) {
        return;
      }
      _listeners.forEach((k, v) {
        v.onSegmentReceived(segments.map((e) => TranscriptSegment.fromJson(e)).toList());
      });
      return;
    }

    // Message event
    if (jsonEvent.containsKey("type")) {
      var event = MessageEvent.fromJson(jsonEvent);
      _listeners.forEach((k, v) {
        v.onMessageEventReceived(event);
      });
      return;
    }

    debugPrint(event.toString());
    DebugLogManager.logInfo('transcription_socket_unhandled_message: ${event.toString()}');
  }

  @override
  void onInternetConnectionFailed() {
    debugPrint("onInternetConnectionFailed");
    CaptureLogService.instance.log('socket', 'internet_connection_failed', severity: 'error');

    // Send notification
    NotificationService.instance.clearNotification(3);
    NotificationService.instance.createNotification(
      notificationId: 3,
      title: 'Internet Connection Lost',
      body: 'Your device is offline. Transcription is paused until connection is restored.',
    );
    DebugLogManager.logEvent('internet_connection_lost', {});

    // Propagate to listeners so the pipeline can auto-finalize
    _listeners.forEach((k, v) {
      v.onTerminalFailure('internet_connection_failed');
    });
  }

  @override
  void onMaxRetriesReach() {
    debugPrint("onMaxRetriesReach");
    CaptureLogService.instance.log('socket', 'socket_max_retries_reached', severity: 'error', details: {
      'custom_stt': customSttMode,
    });

    // Send notification
    NotificationService.instance.clearNotification(2);
    NotificationService.instance.createNotification(
      notificationId: 2,
      title: 'Connection Issue 🚨',
      body: 'Unable to connect to the transcript service.'
          ' Please restart the app or contact support if the problem persists.',
    );
    DebugLogManager.logEvent('transcription_socket_max_retries', {});

    // Propagate to listeners so the pipeline can auto-finalize
    _listeners.forEach((k, v) {
      v.onTerminalFailure('max_retries_reached');
    });
  }

  @override
  void onConnected() {
    _listeners.forEach((k, v) {
      v.onConnected();
    });
    DebugLogManager.logEvent('transcription_socket_connected', {
      'sample_rate': sampleRate,
      'codec': codec.toString(),
      'language': language,
      'include_speech_profile': includeSpeechProfile,
    });
  }
}

class TranscriptSocketServiceFactory {
  TranscriptSocketServiceFactory._();

  /// Codecs supported by custom STT providers
  static const List<BleAudioCodec> _customSttSupportedCodecs = [
    BleAudioCodec.pcm8,
    BleAudioCodec.pcm16,
    BleAudioCodec.opus,
    BleAudioCodec.opusFS320,
  ];

  /// Check if a codec is supported for custom STT
  static bool isCodecSupportedForCustomStt(BleAudioCodec codec) {
    return _customSttSupportedCodecs.contains(codec);
  }

  /// Create default Omi transcription service
  static TranscriptSegmentSocketService createDefault(
    int sampleRate,
    BleAudioCodec codec,
    String language, {
    bool includeSpeechProfile = true,
    String? source,
    String? sttConfigId,
  }) {
    return TranscriptSegmentSocketService.create(
      sampleRate,
      codec,
      language,
      includeSpeechProfile: includeSpeechProfile,
      source: source,
      sttConfigId: sttConfigId ?? 'omi:default',
    );
  }

  /// Create speech profile transcription service
  static TranscriptSegmentSocketService createSpeechProfile(
    int sampleRate,
    BleAudioCodec codec,
    String language, {
    String? source,
  }) {
    return SpeechProfileTranscriptSegmentSocketService.create(
      sampleRate,
      codec,
      language,
      source: source,
    );
  }

  /// Main entry point: Create transcription service from CustomSttConfig
  /// Uses config.isLive to decide between streaming and polling sockets
  static TranscriptSegmentSocketService createFromCustomConfig(
    int sampleRate,
    BleAudioCodec codec,
    String language,
    CustomSttConfig config, {
    String? source,
  }) {
    if (!config.isEnabled) {
      return createDefault(sampleRate, codec, language, source: source);
    }

    // Local on-device: Parakeet or Moonshine, no composite wrapper needed
    if (config.provider == SttProvider.localParakeet) {
      return createLocalStt(sampleRate, codec, language, source: source);
    }
    if (config.provider == SttProvider.localMoonshine) {
      return createLocalStt(sampleRate, codec, language,
          source: source, modelType: LocalSttModelType.moonshine);
    }
    if (config.provider == SttProvider.localCanary) {
      return createLocalStt(sampleRate, codec, language,
          source: source, modelType: LocalSttModelType.canary);
    }

    final sttConfigId = config.sttConfigId;
    final effectiveLang = config.effectiveLanguage;
    final effectiveModel = config.effectiveModel;
    debugPrint(
        "[STTFactory] Creating socket: provider=${config.provider.name}, isLive=${config.isLive}, lang=$effectiveLang, model=$effectiveModel");

    // Create primary socket based on isLive/isPolling
    final primarySocket = config.isLive
        ? _createStreamingSocket(sampleRate, codec, config)
        : _createPollingSocket(sampleRate, codec, config);

    // Wrap with composite service (primary STT + Omi backend)
    return _createCompositeService(
      sampleRate,
      codec,
      effectiveLang,
      primarySocket: primarySocket,
      source: source,
      sttConfigId: sttConfigId,
      sttProvider: config.provider.name,
    );
  }

  /// Create transcription service using ONLY custom STT (Deepgram, etc.)
  /// without the Omi backend composite wrapper.
  /// Use this when Omi backend authentication is not available.
  static TranscriptSegmentSocketService createCustomSttOnly(
    int sampleRate,
    BleAudioCodec codec,
    String language,
    CustomSttConfig config, {
    String? source,
  }) {
    if (!config.isEnabled) {
      debugPrint("[STTFactory] Config not enabled, falling back to default");
      return createDefault(sampleRate, codec, language, source: source);
    }

    // Local on-device engine: Parakeet or Moonshine, no network
    if (config.provider == SttProvider.localParakeet) {
      return createLocalStt(sampleRate, codec, language, source: source);
    }
    if (config.provider == SttProvider.localMoonshine) {
      return createLocalStt(sampleRate, codec, language,
          source: source, modelType: LocalSttModelType.moonshine);
    }
    if (config.provider == SttProvider.localCanary) {
      return createLocalStt(sampleRate, codec, language,
          source: source, modelType: LocalSttModelType.canary);
    }

    final sttConfigId = config.sttConfigId;
    debugPrint(
        "[STTFactory] Creating DIRECT socket (no composite): provider=${config.provider.name}, isLive=${config.isLive}");

    // Create the streaming/polling socket
    final customSocket = config.isLive
        ? _createStreamingSocket(sampleRate, codec, config)
        : _createPollingSocket(sampleRate, codec, config);

    // Return wrapped in TranscriptSegmentSocketService WITHOUT composite
    return TranscriptSegmentSocketService.withSocket(
      sampleRate,
      codec,
      language,
      customSocket,
      includeSpeechProfile: false,
      source: source,
      customSttMode: true,
      sttConfigId: sttConfigId,
    );
  }

  /// Create a local STT transcription service using an on-device model.
  /// No network required -- audio is decoded locally via sherpa_onnx.
  ///
  /// Each call creates a fresh [LocalSttSocket] whose [connect] spawns a new
  /// worker isolate with its own engine instance.  This ensures a clean VAD
  /// state on every reconnect.
  static TranscriptSegmentSocketService createLocalStt(
    int sampleRate,
    BleAudioCodec codec,
    String language, {
    String? source,
    LocalSttModelType modelType = LocalSttModelType.parakeet,
  }) {
    final prefs = SharedPreferencesUtil();
    final modelPath = switch (modelType) {
      LocalSttModelType.moonshine => prefs.localSttMoonshinePath,
      LocalSttModelType.canary => prefs.localSttCanaryPath,
      LocalSttModelType.parakeet => prefs.localSttModelPath,
    };
    debugPrint(
        '[STTFactory] Creating LocalSttSocket, model: ${modelType.name}, path: $modelPath');

    if (modelPath.isEmpty) {
      debugPrint(
          '[STTFactory] ERROR: ${modelType.name} model path is empty — cannot create local STT');
      throw StateError(
          '${modelType.name} model path not configured. Download the model first.');
    }

    // Load speaker model path and user embedding for on-device speaker ID
    String? speakerModelPath;
    Uint8List? userEmbeddingBytes;

    final speakerPath = prefs.speakerModelPath;
    final embeddingPath = prefs.localSpeakerEmbeddingPath;

    if (speakerPath.isNotEmpty && embeddingPath.isNotEmpty) {
      final embeddingFile = File(embeddingPath);
      if (embeddingFile.existsSync()) {
        final bytes = embeddingFile.readAsBytesSync();
        if (bytes.length == 192 * 4) {
          speakerModelPath = speakerPath;
          userEmbeddingBytes = bytes;
          debugPrint('[STTFactory] Speaker ID enabled for local STT');
        }
      }
    }

    // Canary uses shorter maxSpeechDuration for faster decode (configurable)
    final maxSpeechDuration = modelType == LocalSttModelType.canary
        ? prefs.localSttCanaryMaxSpeechDuration
        : null;

    final localSocket = LocalSttSocket(
      modelPath: modelPath,
      modelType: modelType,
      speakerModelPath: speakerModelPath,
      userEmbeddingBytes: userEmbeddingBytes,
      maxSpeechDuration: maxSpeechDuration,
    );

    final service = TranscriptSegmentSocketService.withSocket(
      sampleRate,
      codec,
      language,
      localSocket,
      includeSpeechProfile: false,
      source: source,
      customSttMode: true,
      sttConfigId: '${modelType.name}:ondevice',
    );

    // Wire live preview from local socket to pipeline listeners
    localSocket.onPreviewText = (text) => service.notifyPreview(text);

    return service;
  }

  /// Create streaming WebSocket for live STT
  static IPureSocket _createStreamingSocket(
    int sampleRate,
    BleAudioCodec codec,
    CustomSttConfig config,
  ) {
    final transcoder = AudioTranscoderFactory.createToRawPcm(
      sourceCodec: codec,
      sampleRate: sampleRate,
    );

    // Special case: Gemini Live has unique protocol (setup message, base64 audio)
    if (config.provider == SttProvider.geminiLive) {
      return GeminiStreamingSttSocket(
        apiKey: config.apiKey ?? '',
        model: config.effectiveModel.isNotEmpty ? config.effectiveModel : 'gemini-2.0-flash-live-001',
        language: config.effectiveLanguage,
        sampleRate: sampleRate,
        transcoder: transcoder,
      );
    }

    // Deepgram Live and other streaming providers
    final requestConfig = config.requestConfig;
    final url = requestConfig['url'] ?? config.effectiveUrl;
    final headers =
        requestConfig['headers'] != null ? Map<String, String>.from(requestConfig['headers']) : (config.headers ?? {});
    final params =
        requestConfig['params'] != null ? Map<String, String>.from(requestConfig['params']) : (config.params ?? {});

    // Build WebSocket URL with query params
    final wsUrl = _buildUrlWithParams(url, params);

    return PureStreamingSttSocket(
      config: StreamingSttConfig.schemaBased(
        wsUrl: wsUrl,
        schema: config.schema,
        headers: headers,
        transcoder: transcoder,
        serviceId: config.provider.name,
        sendKeepAlive: config.provider == SttProvider.deepgramLive,
        keepAliveInterval: const Duration(seconds: 8),
      ),
    );
  }

  /// Create polling HTTP socket for batch STT
  static IPureSocket _createPollingSocket(
    int sampleRate,
    BleAudioCodec codec,
    CustomSttConfig config,
  ) {
    final transcoder = AudioTranscoderFactory.createToWav(
      sourceCodec: codec,
      sampleRate: sampleRate,
    );

    final requestConfig = config.requestConfig;
    final url = requestConfig['url'] ?? config.effectiveUrl;
    final headers =
        requestConfig['headers'] != null ? Map<String, String>.from(requestConfig['headers']) : (config.headers ?? {});
    final params =
        requestConfig['params'] != null ? Map<String, String>.from(requestConfig['params']) : (config.params ?? {});
    final audioFieldName = requestConfig['audio_field_name'] ?? config.audioFieldName ?? 'file';
    final requestType = config.effectiveRequestType;

    // Build URL with query params for raw_binary type
    final effectiveUrl = requestType == SttRequestType.rawBinary ? _buildUrlWithParams(url, params) : url;

    return PurePollingSocket(
      config: AudioPollingConfig(
        bufferDuration: const Duration(seconds: 5),
        minBufferSizeBytes: sampleRate * 2,
        serviceId: config.provider.name,
        transcoder: transcoder,
      ),
      sttProvider: SchemaBasedSttProvider(
        apiUrl: effectiveUrl,
        schema: config.schema,
        defaultHeaders: headers,
        defaultFields: requestType == SttRequestType.rawBinary ? {} : params,
        audioFieldName: audioFieldName,
        requestType: requestType,
      ),
    );
  }

  /// Build URL with query parameters
  static String _buildUrlWithParams(String baseUrl, Map<String, String> params) {
    if (params.isEmpty) return baseUrl;
    final uri = Uri.parse(baseUrl);
    final newUri = uri.replace(queryParameters: {...uri.queryParameters, ...params});
    return newUri.toString();
  }

  /// Create composite service: primary STT socket + Omi backend for conversation processing
  static TranscriptSegmentSocketService _createCompositeService(
    int sampleRate,
    BleAudioCodec codec,
    String language, {
    required IPureSocket primarySocket,
    String? source,
    String? sttConfigId,
    String? sttProvider,
  }) {
    final secondaryService = CustomSttTranscriptSegmentSocketService.create(
      sampleRate,
      codec,
      language,
      source: source,
    );
    final compositeSocket = CompositeTranscriptionSocket(
      primarySocket: primarySocket,
      secondarySocket: secondaryService.socket,
      sttProvider: sttProvider,
    );
    return TranscriptSegmentSocketService.withSocket(
      sampleRate,
      codec,
      language,
      compositeSocket,
      source: source,
      customSttMode: true,
      sttConfigId: sttConfigId,
    );
  }
}
