import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:omi/services/sockets/pure_socket.dart';
import 'package:omi/services/custom_stt_log_service.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/models/stt_response_schema.dart';
import 'package:omi/models/stt_result.dart';
import 'package:omi/utils/audio/audio_transcoder.dart';
import 'package:omi/utils/debug_log_manager.dart';

/// Configuration for streaming STT WebSocket connections
class StreamingSttConfig {
  final String url;
  final Map<String, String> headers;
  final SttResponseSchema responseSchema;
  final IAudioTranscoder? transcoder;
  final String serviceId;
  final int minBytesBeforeSend;
  final bool sendKeepAlive;
  final Duration keepAliveInterval;

  const StreamingSttConfig({
    required this.url,
    this.headers = const {},
    required this.responseSchema,
    this.transcoder,
    this.serviceId = 'streaming-stt',
    this.minBytesBeforeSend = 0,
    this.sendKeepAlive = false,
    this.keepAliveInterval = const Duration(seconds: 10),
  });

  /// Alias for backward compatibility
  String get wsUrl => url;

  /// Factory for generic schema-based streaming WebSocket
  factory StreamingSttConfig.schemaBased({
    required String wsUrl,
    required SttResponseSchema schema,
    Map<String, String> headers = const {},
    IAudioTranscoder? transcoder,
    String serviceId = 'custom-streaming',
    int minBytesBeforeSend = 0,
    bool sendKeepAlive = false,
    Duration keepAliveInterval = const Duration(seconds: 10),
  }) {
    return StreamingSttConfig(
      url: wsUrl,
      headers: headers,
      responseSchema: schema,
      transcoder: transcoder,
      serviceId: serviceId,
      minBytesBeforeSend: minBytesBeforeSend,
      sendKeepAlive: sendKeepAlive,
      keepAliveInterval: keepAliveInterval,
    );
  }
}

/// Gemini Live streaming socket with setup message and base64 audio encoding
class GeminiStreamingSttSocket implements IPureSocket {
  StreamSubscription<bool>? _connectionStateListener;
  bool _isConnected = ConnectivityService().isConnected;
  Timer? _internetLostDelayTimer;
  bool _stopped = false;  // Prevents reconnects after stop() is called

  WebSocketChannel? _channel;

  final String apiKey;
  final String model;
  final String language;
  final int sampleRate;
  final IAudioTranscoder? transcoder;

  PureSocketStatus _status = PureSocketStatus.notConnected;
  @override
  PureSocketStatus get status => _status;

  IPureSocketListener? _listener;

  int _retries = 0;
  double _audioOffsetSeconds = 0;
  bool _setupSent = false;

  final List<Uint8List> _frameBuffer = [];
  int _bufferedBytes = 0;
  static const int _minBytesBeforeSend = 16000;

  GeminiStreamingSttSocket({
    required this.apiKey,
    this.model = 'gemini-2.0-flash-live-001',
    this.language = 'en',
    this.sampleRate = 16000,
    this.transcoder,
  }) {
    _connectionStateListener = ConnectivityService().onConnectionChange.listen((bool isConnected) {
      onConnectionStateChanged(isConnected);
    });
  }

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  String get _wsUrl =>
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey';

  @override
  Future<bool> connect() async {
    DebugLogManager.logEvent('gemini_stt_connect_attempt', {
      'status': _status.name,
      'stopped': _stopped,
    });

    if (_stopped) {
      CustomSttLogService.instance.info('GeminiStreaming', 'Connect ignored - socket was stopped');
      return false;
    }
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      debugPrint('[GeminiStreaming] Connect ignored - already $_status');
      return false;
    }

    CustomSttLogService.instance.info('GeminiStreaming', 'Connecting...');
    debugPrint('[GeminiStreaming] Connecting...');
    _status = PureSocketStatus.connecting;

    try {
      _channel = IOWebSocketChannel.connect(
        _wsUrl,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 15),
      );

      await _channel!.ready;

      _status = PureSocketStatus.connected;
      _retries = 0;
      _setupSent = false;

      _channel!.stream.listen(
        _handleMessage,
        onError: (err, trace) => onError(err, trace),
        onDone: () => onClosed(_channel?.closeCode),
        cancelOnError: true,
      );

      await _sendSetupMessage();

      onConnected();
      return true;
    } on TimeoutException catch (e) {
      CustomSttLogService.instance.error('GeminiStreaming', 'Connection timeout: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    } on SocketException catch (e) {
      CustomSttLogService.instance.error('GeminiStreaming', 'Socket error: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    } on WebSocketChannelException catch (e) {
      CustomSttLogService.instance.error('GeminiStreaming', 'WebSocket error: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    } catch (e) {
      CustomSttLogService.instance.error('GeminiStreaming', 'Connection error: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    }
  }

  Future<void> _sendSetupMessage() async {
    if (_setupSent) return;

    final setupMessage = {
      'setup': {
        'model': 'models/$model',
        'generationConfig': {
          'responseModalities': ['TEXT'],
        },
        'systemInstruction': {
          'parts': [
            {
              'text': 'You are a speech-to-text transcription service. '
                  'Listen to the audio and transcribe it accurately in $language. '
                  'Return only the transcription text, no explanations or formatting. '
                  'If you cannot understand the audio, return an empty string.',
            }
          ]
        }
      }
    };

    try {
      _channel!.sink.add(jsonEncode(setupMessage));
      _setupSent = true;
      CustomSttLogService.instance.info('GeminiStreaming', 'Setup message sent');
    } catch (e) {
      CustomSttLogService.instance.error('GeminiStreaming', 'Failed to send setup: $e');
    }
  }

  void _handleMessage(dynamic message) {
    String messageStr;
    if (message is String) {
      messageStr = message;
    } else if (message is List<int>) {
      // Binary WebSocket frame - decode as UTF-8
      try {
        messageStr = utf8.decode(message);
      } catch (e) {
        debugPrint("[GeminiStreaming] Failed to decode binary message: $e");
        return;
      }
    } else {
      debugPrint("[GeminiStreaming] Unsupported message type: ${message.runtimeType}");
      return;
    }

    try {
      final json = jsonDecode(messageStr);

      if (json.containsKey('setupComplete')) {
        CustomSttLogService.instance.info('GeminiStreaming', 'Setup complete');
        return;
      }

      if (json.containsKey('toolCall')) {
        return;
      }

      String? text;
      if (json.containsKey('serverContent')) {
        final serverContent = json['serverContent'];
        if (serverContent != null && serverContent.containsKey('modelTurn')) {
          final modelTurn = serverContent['modelTurn'];
          if (modelTurn != null && modelTurn.containsKey('parts')) {
            final parts = modelTurn['parts'] as List?;
            if (parts != null && parts.isNotEmpty) {
              text = parts[0]['text'] as String?;
            }
          }
        }
      }

      if (text != null && text.trim().isNotEmpty) {
        // Generate unique ID based on timestamp and audio offset
        final segmentId = '${DateTime.now().millisecondsSinceEpoch}_${_audioOffsetSeconds.toStringAsFixed(2)}';

        final segment = {
          'id': segmentId,  // Unique ID for segment accumulation
          'text': text.trim(),
          'speaker': 'SPEAKER_0',
          'speaker_id': 0,
          'is_user': true,  // Gemini streaming: user is always speaker 0
          'start': _audioOffsetSeconds,
          'end': _audioOffsetSeconds + 3.0,
          'person_id': null,
        };
        _audioOffsetSeconds += 3.0;

        onMessage(jsonEncode([segment]));
      }
    } catch (e, trace) {
      CustomSttLogService.instance.error('GeminiStreaming', 'Parse error: $e');
      debugPrintStack(stackTrace: trace);
    }
  }

  @override
  void send(dynamic message) {
    if (_status != PureSocketStatus.connected || _channel == null || !_setupSent) {
      return;
    }

    Uint8List audioData;
    if (message is Uint8List) {
      audioData = message;
    } else if (message is List<int>) {
      audioData = Uint8List.fromList(message);
    } else {
      CustomSttLogService.instance.warning('GeminiStreaming', 'Unsupported message type: ${message.runtimeType}');
      return;
    }

    _frameBuffer.add(audioData);
    _bufferedBytes += audioData.length;

    if (_bufferedBytes < _minBytesBeforeSend) {
      return;
    }

    Uint8List pcmData;
    if (transcoder != null) {
      // Transcode individual frames (important for Opus which needs frame boundaries)
      try {
        pcmData = transcoder!.transcodeFrames(_frameBuffer);
      } catch (e) {
        CustomSttLogService.instance.error('GeminiStreaming', 'Transcode error: $e');
        _frameBuffer.clear();
        _bufferedBytes = 0;
        return;
      }
    } else {
      // Only combine if no transcoding needed (raw PCM)
      pcmData = Uint8List(_bufferedBytes);
      int offset = 0;
      for (final frame in _frameBuffer) {
        pcmData.setRange(offset, offset + frame.length, frame);
        offset += frame.length;
      }
    }
    _frameBuffer.clear();
    _bufferedBytes = 0;

    final realtimeInput = {
      'realtimeInput': {
        'mediaChunks': [
          {
            'mimeType': 'audio/pcm;rate=$sampleRate',
            'data': base64Encode(pcmData),
          }
        ]
      }
    };

    try {
      _channel!.sink.add(jsonEncode(realtimeInput));
    } catch (e) {
      CustomSttLogService.instance.error('GeminiStreaming', 'Send error: $e');
    }
  }

  @override
  Future disconnect() async {
    if (_bufferedBytes > 0 && _status == PureSocketStatus.connected) {
      final combined = Uint8List(_bufferedBytes);
      int offset = 0;
      for (final frame in _frameBuffer) {
        combined.setRange(offset, offset + frame.length, frame);
        offset += frame.length;
      }
      _frameBuffer.clear();
      _bufferedBytes = 0;

      Uint8List pcmData = combined;
      if (transcoder != null) {
        try {
          pcmData = transcoder!.transcodeFrames([combined]);
        } catch (_) {}
      }

      final realtimeInput = {
        'realtimeInput': {
          'mediaChunks': [
            {
              'mimeType': 'audio/pcm;rate=$sampleRate',
              'data': base64Encode(pcmData),
            }
          ]
        }
      };

      try {
        _channel!.sink.add(jsonEncode(realtimeInput));
      } catch (_) {}
    }

    await Future.delayed(const Duration(milliseconds: 500));

    _channel?.sink.close();
    _status = PureSocketStatus.disconnected;
    CustomSttLogService.instance.info('GeminiStreaming', 'Disconnected');
    onClosed();
  }

  Future _cleanUp() async {
    _internetLostDelayTimer?.cancel();
    _connectionStateListener?.cancel();
    _frameBuffer.clear();
    _bufferedBytes = 0;
    _audioOffsetSeconds = 0;
    _setupSent = false;
  }

  @override
  Future stop() async {
    DebugLogManager.logEvent('gemini_stt_stop', {
      'status': _status.name,
      'was_stopped': _stopped,
    });
    debugPrint('[GeminiStreaming] stop() called - status: $_status');
    _stopped = true;  // Prevent any further reconnect attempts
    await disconnect();
    await _cleanUp();
  }

  @override
  void onConnected() {
    DebugLogManager.logEvent('gemini_stt_connected', {});
    CustomSttLogService.instance.info('GeminiStreaming', 'Connected');
    debugPrint('[GeminiStreaming] Connected');
    _listener?.onConnected();
  }

  @override
  void onMessage(dynamic message) {
    _listener?.onMessage(message);
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    DebugLogManager.logEvent('gemini_stt_closed', {
      'close_code': closeCode ?? -1,
    });
    CustomSttLogService.instance.warning('GeminiStreaming', 'Closed with code: $closeCode');
    debugPrint('[GeminiStreaming] Closed - code: $closeCode');
    _listener?.onClosed(closeCode);
  }

  @override
  void onError(Object err, StackTrace trace) {
    CustomSttLogService.instance.error('GeminiStreaming', 'Error: $err');
    debugPrint('[GeminiStreaming] Error: $err');
    _listener?.onError(err, trace);
  }

  void _reconnect() async {
    DebugLogManager.logEvent('gemini_stt_reconnect_attempt', {
      'status': _status.name,
      'stopped': _stopped,
      'retries': _retries,
    });

    if (_stopped) {
      CustomSttLogService.instance.info('GeminiStreaming', 'Reconnect skipped - socket was stopped');
      debugPrint('[GeminiStreaming] Reconnect skipped - socket was stopped');
      return;
    }
    CustomSttLogService.instance.info('GeminiStreaming', 'Reconnecting... attempt ${_retries + 1}');
    debugPrint('[GeminiStreaming] Reconnect attempt ${_retries + 1}');
    const int initialBackoffTimeMs = 1000;
    const double multiplier = 1.5;
    const int maxRetries = 8;

    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      debugPrint('[GeminiStreaming] Reconnect skipped - already $_status');
      return;
    }

    await _cleanUp();

    var ok = await connect();
    if (ok) {
      DebugLogManager.logEvent('gemini_stt_reconnect_success', {
        'retries': _retries,
      });
      return;
    }

    int waitInMilliseconds = pow(multiplier, _retries).toInt() * initialBackoffTimeMs;
    debugPrint('[GeminiStreaming] Waiting ${waitInMilliseconds}ms before retry...');
    await Future.delayed(Duration(milliseconds: waitInMilliseconds));

    // Double-check stopped flag after delay
    if (_stopped) {
      CustomSttLogService.instance.info('GeminiStreaming', 'Reconnect aborted after delay - socket was stopped');
      debugPrint('[GeminiStreaming] Reconnect aborted after delay - socket was stopped');
      return;
    }

    _retries++;
    if (_retries > maxRetries) {
      DebugLogManager.logEvent('gemini_stt_max_retries', {
        'retries': _retries,
      });
      CustomSttLogService.instance.error('GeminiStreaming', 'Max retries reached');
      debugPrint('[GeminiStreaming] Max retries ($maxRetries) reached');
      _listener?.onMaxRetriesReach();
      return;
    }
    _reconnect();
  }

  @override
  void onConnectionStateChanged(bool isConnected) {
    DebugLogManager.logEvent('gemini_stt_connection_changed', {
      'internet_connected': isConnected,
      'socket_status': _status.name,
      'stopped': _stopped,
    });
    CustomSttLogService.instance.info('GeminiStreaming', 'Internet: $isConnected, status: $_status');
    debugPrint('[GeminiStreaming] Internet: $isConnected, socket: $_status, stopped: $_stopped');
    _isConnected = isConnected;
    if (isConnected) {
      if (_status == PureSocketStatus.connected || _status == PureSocketStatus.connecting) {
        return;
      }
      _reconnect();
    } else {
      _internetLostDelayTimer?.cancel();
      _internetLostDelayTimer = Timer(const Duration(seconds: 60), () async {
        if (_isConnected) return;
        debugPrint('[GeminiStreaming] Internet lost for 60s - disconnecting');
        await disconnect();
        _listener?.onInternetConnectionFailed();
      });
    }
  }
}

/// Streaming STT socket that sends audio immediately and receives transcripts in real-time
class PureStreamingSttSocket implements IPureSocket {
  StreamSubscription<bool>? _connectionStateListener;
  bool _isConnected = ConnectivityService().isConnected;
  Timer? _internetLostDelayTimer;
  Timer? _keepAliveTimer;
  bool _stopped = false;  // Prevents reconnects after stop() is called

  WebSocketChannel? _channel;

  final StreamingSttConfig config;

  PureSocketStatus _status = PureSocketStatus.notConnected;
  @override
  PureSocketStatus get status => _status;

  IPureSocketListener? _listener;

  int _retries = 0;
  double _audioOffsetSeconds = 0;

  // Buffer for accumulating small frames before sending
  final List<Uint8List> _frameBuffer = [];
  int _bufferedBytes = 0;

  PureStreamingSttSocket({required this.config}) {
    _connectionStateListener = ConnectivityService().onConnectionChange.listen((bool isConnected) {
      onConnectionStateChanged(isConnected);
    });
  }

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    DebugLogManager.logEvent('streaming_stt_connect_attempt', {
      'service_id': config.serviceId,
      'status': _status.name,
      'stopped': _stopped,
    });

    if (_stopped) {
      CustomSttLogService.instance.info(config.serviceId, 'Connect ignored - socket was stopped');
      return false;
    }
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      debugPrint('[StreamingSTT] Connect ignored - already $_status');
      return false;
    }

    CustomSttLogService.instance.info(config.serviceId, 'Connecting...');
    debugPrint('[StreamingSTT] Connecting to ${config.serviceId}...');
    _status = PureSocketStatus.connecting;

    try {
      _channel = IOWebSocketChannel.connect(
        config.url,
        headers: config.headers,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 15),
      );

      await _channel!.ready;

      _status = PureSocketStatus.connected;
      _retries = 0;
      onConnected();

      _channel!.stream.listen(
        _handleMessage,
        onError: (err, trace) => onError(err, trace),
        onDone: () => onClosed(_channel?.closeCode),
        cancelOnError: true,
      );

      _startKeepAlive();

      return true;
    } on TimeoutException catch (e) {
      CustomSttLogService.instance.error(config.serviceId, 'Connection timeout: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    } on SocketException catch (e) {
      CustomSttLogService.instance.error(config.serviceId, 'Socket error: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    } on WebSocketChannelException catch (e) {
      CustomSttLogService.instance.error(config.serviceId, 'WebSocket error: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    } catch (e) {
      CustomSttLogService.instance.error(config.serviceId, 'Connection error: $e');
      _status = PureSocketStatus.notConnected;
      return false;
    }
  }

  void _startKeepAlive() {
    if (!config.sendKeepAlive) return;

    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(config.keepAliveInterval, (_) {
      if (_status == PureSocketStatus.connected && _channel != null) {
        try {
          _channel!.sink.add(jsonEncode({'type': 'KeepAlive'}));
        } catch (e) {
          CustomSttLogService.instance.warning(config.serviceId, 'Keep-alive error: $e');
        }
      }
    });
  }

  void _handleMessage(dynamic message) {
    if (message is! String) {
      CustomSttLogService.instance.warning(config.serviceId, 'Non-string message received');
      return;
    }

    try {
      final json = jsonDecode(message);

      // Handle Deepgram-specific message types
      if (json is Map && json.containsKey('type')) {
        final type = json['type'];
        if (type == 'Metadata' || type == 'UtteranceEnd') {
          debugPrint("[StreamingSTT] Received $type message");
          return;
        }
        if (type != 'Results') {
          return;
        }
      }

      // Parse using schema
      final result = SttTranscriptionResult.fromJsonWithSchema(
        json,
        config.responseSchema,
        audioOffsetSeconds: 0,
      );

      if (result.isNotEmpty) {
        if (result.segments.isNotEmpty) {
          _audioOffsetSeconds = result.segments.last.end;
        }

        // Aggregate words by speaker (matching backend TranscriptSegment format)
        final segments = <Map<String, dynamic>>[];
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        var segmentIndex = 0;

        for (final segment in result.segments) {
          if (segment.text.trim().isEmpty) continue;

          final speakerId = segment.speakerId;
          final speaker = 'SPEAKER_$speakerId';

          if (segments.isEmpty || segments.last['speaker'] != speaker) {
            // Generate unique ID based on timestamp, start time, and index
            final segmentId = '${timestamp}_${segment.start.toStringAsFixed(2)}_$segmentIndex';
            segmentIndex++;

            segments.add({
              'id': segmentId,  // Unique ID for segment accumulation
              'text': segment.text.trim(),
              'speaker': speaker,
              'speaker_id': speakerId,
              'is_user': speakerId == 0,  // Speaker 0 = user (closest to OMI mic)
              'start': segment.start,
              'end': segment.end,
              'person_id': null,
            });
          } else {
            final last = segments.last;
            last['text'] = '${last['text']} ${segment.text.trim()}';
            last['end'] = segment.end;
          }
        }

        if (segments.isNotEmpty) {
          onMessage(jsonEncode(segments));
        }
      }
    } catch (e, trace) {
      CustomSttLogService.instance.error(config.serviceId, 'Parse error: $e');
      debugPrintStack(stackTrace: trace);
    }
  }

  @override
  void send(dynamic message) {
    if (_status != PureSocketStatus.connected || _channel == null) {
      return;
    }

    Uint8List audioData;
    if (message is Uint8List) {
      audioData = message;
    } else if (message is List<int>) {
      audioData = Uint8List.fromList(message);
    } else {
      CustomSttLogService.instance.warning(config.serviceId, 'Unsupported message type: ${message.runtimeType}');
      return;
    }

    // Buffer frames if minimum bytes threshold is set
    if (config.minBytesBeforeSend > 0) {
      _frameBuffer.add(audioData);
      _bufferedBytes += audioData.length;

      if (_bufferedBytes < config.minBytesBeforeSend) {
        return;
      }

      // Transcode individual frames (important for Opus which needs frame boundaries)
      if (config.transcoder != null) {
        try {
          audioData = config.transcoder!.transcodeFrames(_frameBuffer);
        } catch (e) {
          CustomSttLogService.instance.error(config.serviceId, 'Transcode error: $e');
          _frameBuffer.clear();
          _bufferedBytes = 0;
          return;
        }
      } else {
        // Only combine if no transcoding needed (raw PCM)
        final combined = Uint8List(_bufferedBytes);
        int offset = 0;
        for (final frame in _frameBuffer) {
          combined.setRange(offset, offset + frame.length, frame);
          offset += frame.length;
        }
        audioData = combined;
      }
      _frameBuffer.clear();
      _bufferedBytes = 0;
    } else {
      // No buffering - transcode single frame
      if (config.transcoder != null) {
        try {
          audioData = config.transcoder!.transcodeFrames([audioData]);
        } catch (e) {
          CustomSttLogService.instance.error(config.serviceId, 'Transcode error: $e');
          return;
        }
      }
    }

    // Send immediately to streaming endpoint
    try {
      _channel!.sink.add(audioData);
    } catch (e) {
      CustomSttLogService.instance.error(config.serviceId, 'Send error: $e');
    }
  }

  /// Send close signal to streaming provider (e.g., Deepgram's CloseStream)
  void sendCloseSignal() {
    if (_status == PureSocketStatus.connected && _channel != null) {
      try {
        _channel!.sink.add(jsonEncode({'type': 'CloseStream'}));
      } catch (e) {
        CustomSttLogService.instance.warning(config.serviceId, 'Close signal error: $e');
      }
    }
  }

  @override
  Future disconnect() async {
    _keepAliveTimer?.cancel();
    sendCloseSignal();

    // Give time for final results
    await Future.delayed(const Duration(milliseconds: 500));

    _channel?.sink.close();
    _status = PureSocketStatus.disconnected;
    CustomSttLogService.instance.info(config.serviceId, 'Disconnected');
    onClosed();
  }

  Future _cleanUp() async {
    _internetLostDelayTimer?.cancel();
    _connectionStateListener?.cancel();
    _keepAliveTimer?.cancel();
    _frameBuffer.clear();
    _bufferedBytes = 0;
    _audioOffsetSeconds = 0;
  }

  @override
  Future stop() async {
    DebugLogManager.logEvent('streaming_stt_stop', {
      'service_id': config.serviceId,
      'status': _status.name,
      'was_stopped': _stopped,
    });
    debugPrint('[StreamingSTT] stop() called - service: ${config.serviceId}, status: $_status');
    _stopped = true;  // Prevent any further reconnect attempts
    await disconnect();
    await _cleanUp();
  }

  @override
  void onConnected() {
    DebugLogManager.logEvent('streaming_stt_connected', {
      'service_id': config.serviceId,
    });
    CustomSttLogService.instance.info(config.serviceId, 'Connected');
    debugPrint('[StreamingSTT] Connected to ${config.serviceId}');
    _listener?.onConnected();
  }

  @override
  void onMessage(dynamic message) {
    _listener?.onMessage(message);
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    DebugLogManager.logEvent('streaming_stt_closed', {
      'service_id': config.serviceId,
      'close_code': closeCode ?? -1,
    });
    CustomSttLogService.instance.warning(config.serviceId, 'Closed with code: $closeCode');
    debugPrint('[StreamingSTT] Closed - service: ${config.serviceId}, code: $closeCode');
    _listener?.onClosed(closeCode);
  }

  @override
  void onError(Object err, StackTrace trace) {
    CustomSttLogService.instance.error(config.serviceId, 'Error: $err');
    _listener?.onError(err, trace);
  }

  void _reconnect() async {
    DebugLogManager.logEvent('streaming_stt_reconnect_attempt', {
      'service_id': config.serviceId,
      'status': _status.name,
      'stopped': _stopped,
      'retries': _retries,
    });

    if (_stopped) {
      CustomSttLogService.instance.info(config.serviceId, 'Reconnect skipped - socket was stopped');
      debugPrint('[StreamingSTT] Reconnect skipped - socket was stopped');
      return;
    }
    CustomSttLogService.instance.info(config.serviceId, 'Reconnecting... attempt ${_retries + 1}');
    debugPrint('[StreamingSTT] Reconnect attempt ${_retries + 1} for ${config.serviceId}');
    const int initialBackoffTimeMs = 1000;
    const double multiplier = 1.5;
    const int maxRetries = 8;

    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      debugPrint('[StreamingSTT] Reconnect skipped - already $_status');
      return;
    }

    await _cleanUp();

    var ok = await connect();
    if (ok) {
      DebugLogManager.logEvent('streaming_stt_reconnect_success', {
        'service_id': config.serviceId,
        'retries': _retries,
      });
      return;
    }

    int waitInMilliseconds = pow(multiplier, _retries).toInt() * initialBackoffTimeMs;
    debugPrint('[StreamingSTT] Waiting ${waitInMilliseconds}ms before retry...');
    await Future.delayed(Duration(milliseconds: waitInMilliseconds));

    // Double-check stopped flag after delay
    if (_stopped) {
      CustomSttLogService.instance.info(config.serviceId, 'Reconnect aborted after delay - socket was stopped');
      debugPrint('[StreamingSTT] Reconnect aborted after delay - socket was stopped');
      return;
    }

    _retries++;
    if (_retries > maxRetries) {
      DebugLogManager.logEvent('streaming_stt_max_retries', {
        'service_id': config.serviceId,
        'retries': _retries,
      });
      CustomSttLogService.instance.error(config.serviceId, 'Max retries reached');
      debugPrint('[StreamingSTT] Max retries ($maxRetries) reached');
      _listener?.onMaxRetriesReach();
      return;
    }
    _reconnect();
  }

  @override
  void onConnectionStateChanged(bool isConnected) {
    DebugLogManager.logEvent('streaming_stt_connection_changed', {
      'service_id': config.serviceId,
      'internet_connected': isConnected,
      'socket_status': _status.name,
      'stopped': _stopped,
    });
    CustomSttLogService.instance.info(config.serviceId, 'Internet: $isConnected, status: $_status');
    debugPrint('[StreamingSTT] Internet: $isConnected, socket: $_status, stopped: $_stopped');
    _isConnected = isConnected;
    if (isConnected) {
      if (_status == PureSocketStatus.connected || _status == PureSocketStatus.connecting) {
        return;
      }
      _reconnect();
    } else {
      _internetLostDelayTimer?.cancel();
      _internetLostDelayTimer = Timer(const Duration(seconds: 60), () async {
        if (_isConnected) return;
        debugPrint('[StreamingSTT] Internet lost for 60s - disconnecting');
        await disconnect();
        _listener?.onInternetConnectionFailed();
      });
    }
  }
}
