import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/supabase_auth_service.dart';
import 'package:omi/utils/logger.dart';
import 'package:http/http.dart' as http;
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:path/path.dart';

class ApiClient {
  static const Duration requestTimeoutRead = Duration(seconds: 30);
  static const Duration requestTimeoutWrite = Duration(seconds: 300);

  static final _client = http.Client();

  static void dispose() {
    _client.close();
  }
}

Future<String> getAuthHeader() async {
  // Usar SupabaseAuthService para obtener el token (maneja auto-refresh internamente)
  final token = await SupabaseAuthService.instance.getAccessToken();

  if (token == null || token.isEmpty) {
    if (SupabaseAuthService.instance.isSignedIn) {
      // Usuario autenticado pero sin token - error
      throw Exception('No auth token found');
    }
    // Usuario no autenticado - retornar vacío
    return '';
  }

  // Actualizar cache local
  SharedPreferencesUtil().authToken = token;

  return 'Bearer $token';
}

/// Builds common headers for API and WebSocket requests
/// Centralizes header logic for easy maintenance and consistency
/// Automatically adds Authorization header if required
Future<Map<String, String>> buildHeaders({
  required bool requireAuthCheck,
  Map<String, String> fromHeaders = const {},
}) async {
  final headers = <String, String>{
    'X-Request-Start-Time': (DateTime.now().millisecondsSinceEpoch / 1000).toString(),
    'X-App-Platform': PlatformManager.instance.platform,
    'X-Device-Id-Hash': PlatformManager.instance.deviceIdHash,
    'X-App-Version': PlatformManager.instance.appVersion,
    ...fromHeaders,
  };

  if (requireAuthCheck) {
    headers['Authorization'] = await getAuthHeader();
  }

  return headers;
}

bool _isRequiredAuthCheck(String url) {
  // Dominios que requieren autenticación con Supabase token
  const authDomains = [
    'maity-backend.vercel.app',
    'maity-mobile.vercel.app',
  ];

  // Verificar dominios que requieren auth
  return authDomains.any((domain) => url.contains(domain));
}

Future<http.StreamedResponse> makeRawApiCall({
  required String url,
  required String method,
  Map<String, String> headers = const {},
}) async {
  var request = http.Request(method, Uri.parse(url));
  final builtHeaders = await buildHeaders(
    requireAuthCheck: _isRequiredAuthCheck(url),
    fromHeaders: headers,
  );
  request.headers.addAll(builtHeaders);
  return ApiClient._client.send(request);
}

/// Result classification for upload retry logic.
enum ApiCallResultType {
  success, // 2xx
  retryable, // Network error, timeout, 5xx
  authFailure, // 401
  permanent, // 400, 422 (bad data, will never succeed)
}

class ApiCallResult {
  final ApiCallResultType type;
  final http.Response? response;
  final String? errorMessage;

  ApiCallResult({required this.type, this.response, this.errorMessage});

  bool get isSuccess => type == ApiCallResultType.success;
}

Future<ApiCallResult> makeApiCallClassified({
  required String url,
  required Map<String, String> headers,
  required String body,
  required String method,
}) async {
  try {
    final bool requireAuthCheck = _isRequiredAuthCheck(url);
    final builtHeaders = await buildHeaders(
      requireAuthCheck: requireAuthCheck,
      fromHeaders: headers,
    );

    http.Response response = await _performRequest(url, builtHeaders, body, method);

    if (requireAuthCheck && response.statusCode == 401) {
      // Try token refresh
      final newToken = await SupabaseAuthService.instance.getAccessToken();
      SharedPreferencesUtil().authToken = newToken ?? '';
      if (SharedPreferencesUtil().authToken.isNotEmpty) {
        final refreshedHeaders = await buildHeaders(
          requireAuthCheck: requireAuthCheck,
          fromHeaders: headers,
        );
        response = await _performRequest(url, refreshedHeaders, body, method);
        if (response.statusCode == 401) {
          return ApiCallResult(type: ApiCallResultType.authFailure, response: response);
        }
      } else {
        return ApiCallResult(type: ApiCallResultType.authFailure, response: response);
      }
    }

    // Classify by status code
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ApiCallResult(type: ApiCallResultType.success, response: response);
    } else if (response.statusCode == 400 || response.statusCode == 422) {
      return ApiCallResult(
        type: ApiCallResultType.permanent,
        response: response,
        errorMessage: 'Server rejected data: ${response.statusCode}',
      );
    } else if (response.statusCode >= 500) {
      return ApiCallResult(type: ApiCallResultType.retryable, response: response);
    } else {
      return ApiCallResult(type: ApiCallResultType.retryable, response: response);
    }
  } on SocketException catch (e) {
    return ApiCallResult(type: ApiCallResultType.retryable, errorMessage: 'Network error: $e');
  } on TimeoutException catch (e) {
    return ApiCallResult(type: ApiCallResultType.retryable, errorMessage: 'Timeout: $e');
  } catch (e) {
    return ApiCallResult(type: ApiCallResultType.retryable, errorMessage: 'Unknown error: $e');
  }
}

Future<http.Response?> makeApiCall({
  required String url,
  required Map<String, String> headers,
  required String body,
  required String method,
}) async {
  try {
    final bool requireAuthCheck = _isRequiredAuthCheck(url);
    final builtHeaders = await buildHeaders(
      requireAuthCheck: requireAuthCheck,
      fromHeaders: headers,
    );

    http.Response? response = await _performRequest(url, builtHeaders, body, method);
    if (requireAuthCheck && response.statusCode == 401) {
      Logger.log('Token expired on 1st attempt');
      // Intentar renovar token con Supabase
      final newToken = await SupabaseAuthService.instance.getAccessToken();
      SharedPreferencesUtil().authToken = newToken ?? '';
      if (SharedPreferencesUtil().authToken.isNotEmpty) {
        final refreshedHeaders = await buildHeaders(
          requireAuthCheck: requireAuthCheck,
          fromHeaders: headers,
        );
        response = await _performRequest(url, refreshedHeaders, body, method);
        Logger.log('Token refreshed and request retried');
        if (response.statusCode == 401) {
          // Log error but DON'T sign out - the external API (api.omi.me) may not accept our tokens
          // This prevents cascading sign-outs when using a different Firebase project
          Logger.handle(Exception('API rejected token (401). External API may not accept this Firebase project.'), StackTrace.current,
              message: 'API rejected token - continuing without sign-out');
          debugPrint('[Auth] 401 from $url - NOT signing out (external API may not accept our Firebase tokens)');
        }
      } else {
        // No token available - log but don't sign out
        Logger.handle(Exception('No auth token available'), StackTrace.current,
            message: 'No auth token - continuing without sign-out');
        debugPrint('[Auth] No token for $url - NOT signing out');
      }
    }

    return response;
  } catch (e, stackTrace) {
    debugPrint('HTTP request failed: $e, $stackTrace');
    PlatformManager.instance.crashReporter.reportCrash(e, stackTrace, userAttributes: {'url': url, 'method': method});
    return null;
  } finally {}
}

Future<http.Response> _performRequest(
  String url,
  Map<String, String> headers,
  String body,
  String method,
) async {
  final client = ApiClient._client;

  switch (method) {
    case 'POST':
      headers['Content-Type'] = 'application/json';
      return await client.post(Uri.parse(url), headers: headers, body: body).timeout(
            ApiClient.requestTimeoutWrite,
            onTimeout: () => throw TimeoutException('Request timeout'),
          );
    case 'GET':
      return await client.get(Uri.parse(url), headers: headers).timeout(
            ApiClient.requestTimeoutRead,
            onTimeout: () => throw TimeoutException('Request timeout'),
          );
    case 'DELETE':
      headers['Content-Type'] = 'application/json';
      return await client.delete(Uri.parse(url), headers: headers, body: body).timeout(
            ApiClient.requestTimeoutWrite,
            onTimeout: () => throw TimeoutException('Request timeout'),
          );
    case 'PATCH':
      headers['Content-Type'] = 'application/json';
      return await client.patch(Uri.parse(url), headers: headers, body: body).timeout(
            ApiClient.requestTimeoutWrite,
            onTimeout: () => throw TimeoutException('Request timeout'),
          );
    case 'PUT':
      headers['Content-Type'] = 'application/json';
      return await client.put(Uri.parse(url), headers: headers, body: body).timeout(
            ApiClient.requestTimeoutWrite,
            onTimeout: () => throw TimeoutException('Request timeout'),
          );
    default:
      throw Exception('Unsupported HTTP method: $method');
  }
}

Future<http.Response> makeMultipartApiCall({
  required String url,
  required List<File> files,
  Map<String, String> headers = const {},
  Map<String, String> fields = const {},
  String fileFieldName = 'files',
  String method = 'POST',
}) async {
  try {
    var request = http.MultipartRequest(method, Uri.parse(url));

    final builtHeaders = await buildHeaders(
      requireAuthCheck: _isRequiredAuthCheck(url),
      fromHeaders: headers,
    );
    request.headers.addAll(builtHeaders);
    request.fields.addAll(fields);

    for (var file in files) {
      var stream = http.ByteStream(file.openRead());
      var length = await file.length();
      var multipartFile = http.MultipartFile(
        fileFieldName,
        stream,
        length,
        filename: basename(file.path),
      );
      request.files.add(multipartFile);
    }

    var streamedResponse = await ApiClient._client.send(request);
    return await http.Response.fromStream(streamedResponse);
  } catch (e, stackTrace) {
    debugPrint('Multipart HTTP request failed: $e, $stackTrace');
    PlatformManager.instance.crashReporter.reportCrash(e, stackTrace, userAttributes: {'url': url, 'method': method});
    rethrow;
  }
}

Stream<String> makeStreamingApiCall({
  required String url,
  Map<String, String> headers = const {},
  String body = '',
  String method = 'POST',
}) async* {
  try {
    var request = http.Request(method, Uri.parse(url));

    final builtHeaders = await buildHeaders(
      requireAuthCheck: _isRequiredAuthCheck(url),
      fromHeaders: headers,
    );
    request.headers.addAll(builtHeaders);

    if (body.isNotEmpty) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body;
    }

    var streamedResponse = await ApiClient._client.send(request);

    if (streamedResponse.statusCode != 200) {
      final errorBody = await streamedResponse.stream.bytesToString();
      Logger.error('Streaming request failed: ${streamedResponse.statusCode}');
      debugPrint('[Chat] Error response body: $errorBody');
      yield 'data: Lo siento, hubo un problema con el servidor (${streamedResponse.statusCode}). Por favor intenta de nuevo.';
      return;
    }

    var buffers = <String>[];
    await for (var data in streamedResponse.stream.transform(utf8.decoder)) {
      var lines = data.split('\n\n');
      for (var line in lines.where((line) => line.isNotEmpty)) {
        // Handle package splitting by 1024 bytes in dart
        if (line.length >= 1024) {
          buffers.add(line);
          continue;
        }

        // Merge packages if needed
        if (buffers.isNotEmpty) {
          buffers.add(line);
          line = buffers.join('\n\n');
          buffers.clear();
        }

        yield line;
      }
    }

    // Flush remaining buffers
    if (buffers.isNotEmpty) {
      yield buffers.join('\n\n');
    }
  } catch (e, stackTrace) {
    Logger.error('Streaming request error: $e');
    PlatformManager.instance.crashReporter.reportCrash(e, stackTrace, userAttributes: {'url': url, 'method': method});
  }
}

Stream<String> makeMultipartStreamingApiCall({
  required String url,
  required List<File> files,
  Map<String, String> headers = const {},
  String fileFieldName = 'files',
}) async* {
  try {
    var request = http.MultipartRequest('POST', Uri.parse(url));

    final builtHeaders = await buildHeaders(
      requireAuthCheck: _isRequiredAuthCheck(url),
      fromHeaders: headers,
    );
    request.headers.addAll(builtHeaders);

    for (var file in files) {
      request.files.add(await http.MultipartFile.fromPath(fileFieldName, file.path, filename: basename(file.path)));
    }

    var response = await ApiClient._client.send(request);

    if (response.statusCode != 200) {
      Logger.error('Multipart streaming request failed: ${response.statusCode}');
      return;
    }

    var buffers = <String>[];
    await for (var data in response.stream.transform(utf8.decoder)) {
      var lines = data.split('\n\n');
      for (var line in lines.where((line) => line.isNotEmpty)) {
        // Handle package splitting by 1024 bytes in dart
        if (line.length >= 1024) {
          buffers.add(line);
          continue;
        }

        // Merge packages if needed
        if (buffers.isNotEmpty) {
          buffers.add(line);
          line = buffers.join('\n\n');
          buffers.clear();
        }

        yield line;
      }
    }

    // Flush remaining buffers
    if (buffers.isNotEmpty) {
      yield buffers.join('\n\n');
    }
  } catch (e, stackTrace) {
    Logger.error('Multipart streaming request error: $e');
    PlatformManager.instance.crashReporter.reportCrash(e, stackTrace, userAttributes: {'url': url, 'method': 'POST'});
  }
}

// Function to extract content from the API response.
dynamic extractContentFromResponse(
  http.Response? response, {
  bool isEmbedding = false,
  bool isFunctionCalling = false,
}) {
  if (response != null && response.statusCode == 200) {
    var data = jsonDecode(response.body);
    if (isEmbedding) {
      var embedding = data['data'][0]['embedding'];
      return embedding;
    }
    var message = data['choices'][0]['message'];
    if (isFunctionCalling && message['tool_calls'] != null) {
      debugPrint('message $message');
      debugPrint('message ${message['tool_calls'].runtimeType}');
      return message['tool_calls'];
    }
    return data['choices'][0]['message']['content'];
  } else {
    debugPrint('Error fetching data: ${response?.statusCode}');
    // TODO: handle error, better specially for script migration
    PlatformManager.instance.crashReporter
        .reportCrash(Exception('Error fetching data: ${response?.statusCode}'), StackTrace.current, userAttributes: {
      'response_null': (response == null).toString(),
      'response_status_code': response?.statusCode.toString() ?? '',
      'is_embedding': isEmbedding.toString(),
      'is_function_calling': isFunctionCalling.toString(),
    });
    return null;
  }
}
