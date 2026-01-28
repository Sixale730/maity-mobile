import 'dart:convert';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/maity_api_service.dart';

/// Service for processing conversations
/// Uses Maity backend (Vercel) when available, falls back to local OpenAI processing
class ConversationProcessor {
  static const String _openAIEndpoint = 'https://api.openai.com/v1/chat/completions';
  static const String _model = 'gpt-4o-mini';
  static const int _maxTokens = 150;
  static const Duration _timeout = Duration(seconds: 30);

  /// Categorías disponibles (32 como Omi)
  static const List<String> categories = [
    'personal', 'education', 'health', 'finance', 'legal', 'philosophy',
    'spiritual', 'science', 'entrepreneurship', 'parenting', 'romantic',
    'travel', 'inspiration', 'technology', 'business', 'social', 'work',
    'sports', 'politics', 'literature', 'history', 'architecture', 'music',
    'weather', 'news', 'entertainment', 'psychology', 'design', 'family',
    'economics', 'environment', 'other',
  ];

  /// Process conversation using Maity backend
  /// Returns full structured data with title, emoji, category, action items, events
  static Future<Structured?> processWithBackend({
    required String userId,
    required List<TranscriptSegment> segments,
    required DateTime startedAt,
    required DateTime finishedAt,
  }) async {
    try {
      debugPrint('[ConversationProcessor] Attempting backend processing...');

      final response = await MaityApiService.processConversation(
        userId: userId,
        segments: segments,
        startedAt: startedAt,
        finishedAt: finishedAt,
      );

      if (response != null) {
        debugPrint('[ConversationProcessor] Backend success: ${response.structured.title}');
        return response.structured;
      }
    } catch (e) {
      debugPrint('[ConversationProcessor] Backend failed: $e');
    }

    // Fallback to local processing
    debugPrint('[ConversationProcessor] Using local OpenAI fallback');
    return await processLocally(segments);
  }

  /// Process conversation locally using OpenAI
  /// Returns structured data with title, emoji, category, overview
  static Future<Structured?> processLocally(List<TranscriptSegment> segments) async {
    if (segments.isEmpty) return null;

    final transcript = segments.map((s) => s.text).join('\n').trim();
    if (transcript.length < 20) {
      return Structured(
        'Conversación corta',
        transcript,
        emoji: '💬',
        category: 'personal',
      );
    }

    final apiKey = Env.openAIAPIKey;
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('[ConversationProcessor] No OpenAI API key, using fallback');
      return _generateFallbackStructured(transcript);
    }

    try {
      debugPrint('[ConversationProcessor] Processing locally with OpenAI...');

      final response = await http
          .post(
            Uri.parse(_openAIEndpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode({
              'model': _model,
              'messages': [
                {
                  'role': 'system',
                  'content': '''Eres un asistente que analiza conversaciones y extrae información estructurada.

CATEGORÍAS DISPONIBLES (elige UNA):
personal, education, health, finance, legal, philosophy, spiritual, science,
entrepreneurship, parenting, romantic, travel, inspiration, technology, business,
social, work, sports, politics, literature, history, architecture, music, weather,
news, entertainment, psychology, design, family, economics, environment, other

IMPORTANTE - Marca "discarded": true si la conversación es IRRELEVANTE:
- Solo saludos casuales sin contenido sustancial ("Hola", "¿Cómo estás?", "Adiós")
- Fragmentos incoherentes o ruido
- No contiene información útil o accionable
- Es muy corta y sin contexto significativo

Responde ÚNICAMENTE en formato JSON:
{
  "title": "Título corto (max 50 chars)",
  "emoji": "Un emoji representativo",
  "overview": "Resumen de 2-3 oraciones",
  "category": "categoria_de_la_lista",
  "discarded": true/false,
  "action_items": [
    {"description": "Tarea específica mencionada"}
  ],
  "events": []
}

NOTAS:
- action_items: tareas, pendientes, compromisos o cosas por hacer mencionadas en la conversación
- events: citas o reuniones con fecha/hora específica (si no hay, array vacío)
- Si no hay action_items, devuelve array vacío []'''
                },
                {
                  'role': 'user',
                  'content': transcript.substring(0, min(6000, transcript.length))
                }
              ],
              'max_tokens': 500,
              'temperature': 0.7,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final content = data['choices']?[0]?['message']?['content'] as String?;

        if (content != null) {
          final result = _parseStructuredResponse(content, transcript);
          if (result != null) {
            debugPrint('[ConversationProcessor] Local processing success: ${result.title}');
            return result;
          }
        }
      } else {
        debugPrint('[ConversationProcessor] OpenAI error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ConversationProcessor] Error in local processing: $e');
    }

    return _generateFallbackStructured(transcript);
  }

  /// Generates a title and emoji for a conversation using OpenAI
  /// Legacy method for backward compatibility
  static Future<Map<String, String>> generateTitleAndEmoji(
    List<TranscriptSegment> segments,
  ) async {
    const defaultResult = {'title': 'Conversación', 'emoji': '🎤'};

    if (segments.isEmpty) {
      return defaultResult;
    }

    final transcript = segments.map((s) => s.text).join('\n').trim();
    if (transcript.length < 20) {
      return {'title': 'Conversación corta', 'emoji': '💬'};
    }

    final apiKey = Env.openAIAPIKey;
    if (apiKey == null || apiKey.isEmpty) {
      return _generateFallbackTitle(transcript);
    }

    try {
      final response = await http
          .post(
            Uri.parse(_openAIEndpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode({
              'model': _model,
              'messages': [
                {
                  'role': 'system',
                  'content': '''Eres un asistente que genera títulos concisos para conversaciones.
Genera un título corto (máximo 50 caracteres) y un emoji relevante para la siguiente conversación.
Responde ÚNICAMENTE en formato JSON: {"title": "...", "emoji": "..."}
El título debe ser descriptivo pero breve, capturando el tema principal.
El emoji debe representar el tema o tono de la conversación.'''
                },
                {
                  'role': 'user',
                  'content': transcript.substring(0, min(1500, transcript.length))
                }
              ],
              'max_tokens': _maxTokens,
              'temperature': 0.7,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final content = data['choices']?[0]?['message']?['content'] as String?;

        if (content != null) {
          final result = _parseJsonResponse(content);
          if (result != null) {
            return result;
          }
        }
      }
    } catch (e) {
      debugPrint('[ConversationProcessor] Error generating title: $e');
    }

    return _generateFallbackTitle(transcript);
  }

  /// Parse structured response from OpenAI
  static Structured? _parseStructuredResponse(String content, String transcript) {
    try {
      String jsonStr = content.trim();

      // Handle markdown code blocks
      if (jsonStr.contains('```json')) {
        jsonStr = jsonStr.split('```json')[1].split('```')[0].trim();
      } else if (jsonStr.contains('```')) {
        jsonStr = jsonStr.split('```')[1].split('```')[0].trim();
      }

      final parsed = jsonDecode(jsonStr);
      final title = parsed['title']?.toString() ?? 'Conversación';
      final emoji = parsed['emoji']?.toString() ?? '🎤';
      final overview = parsed['overview']?.toString() ?? transcript.substring(0, min(300, transcript.length));
      String category = parsed['category']?.toString().toLowerCase() ?? 'other';
      final discarded = parsed['discarded'] == true;

      // Validate category
      if (!categories.contains(category)) {
        category = 'other';
      }

      // Parse action_items
      final actionItemsList = parsed['action_items'] as List? ?? [];
      final actionItems = actionItemsList.map((item) {
        if (item is String) {
          return item.isNotEmpty ? ActionItem(item) : null;
        } else if (item is Map) {
          final desc = item['description']?.toString() ?? '';
          return desc.isNotEmpty ? ActionItem(desc) : null;
        }
        return null;
      }).whereType<ActionItem>().toList();

      // Parse events
      final eventsList = parsed['events'] as List? ?? [];
      final events = eventsList.map((event) {
        if (event is Map) {
          final eventTitle = event['title']?.toString();
          final startStr = event['start']?.toString() ?? event['startsAt']?.toString();
          final duration = event['duration'] ?? event['duration_minutes'] ?? 30;

          if (eventTitle != null && eventTitle.isNotEmpty && startStr != null) {
            try {
              final startsAt = DateTime.parse(startStr);
              return Event(
                eventTitle,
                startsAt,
                duration is int ? duration : int.tryParse(duration.toString()) ?? 30,
                description: event['description']?.toString() ?? '',
              );
            } catch (e) {
              debugPrint('[ConversationProcessor] Error parsing event date: $e');
            }
          }
        }
        return null;
      }).whereType<Event>().toList();

      final result = Structured(
        title.length > 60 ? '${title.substring(0, 57)}...' : title,
        overview,
        emoji: emoji,
        category: category,
        discarded: discarded,
      );
      result.actionItems = actionItems;
      result.events = events;

      debugPrint('[ConversationProcessor] Parsed ${actionItems.length} action items, ${events.length} events');
      return result;
    } catch (e) {
      debugPrint('[ConversationProcessor] Error parsing structured response: $e');
    }
    return null;
  }

  /// Parses the JSON response from OpenAI
  static Map<String, String>? _parseJsonResponse(String content) {
    try {
      String jsonStr = content.trim();

      if (jsonStr.contains('```json')) {
        jsonStr = jsonStr.split('```json')[1].split('```')[0].trim();
      } else if (jsonStr.contains('```')) {
        jsonStr = jsonStr.split('```')[1].split('```')[0].trim();
      }

      final parsed = jsonDecode(jsonStr);
      final title = parsed['title']?.toString();
      final emoji = parsed['emoji']?.toString();

      if (title != null && title.isNotEmpty) {
        return {
          'title': title.length > 60 ? '${title.substring(0, 57)}...' : title,
          'emoji': emoji ?? '🎤',
        };
      }
    } catch (e) {
      debugPrint('[ConversationProcessor] Error parsing JSON: $e');
    }
    return null;
  }

  /// Generate fallback structured data
  static Structured _generateFallbackStructured(String transcript) {
    final titleData = _generateFallbackTitle(transcript);
    final category = _detectCategory(transcript);

    return Structured(
      titleData['title'] ?? 'Conversación',
      transcript.length > 300 ? '${transcript.substring(0, 297)}...' : transcript,
      emoji: titleData['emoji'] ?? '🎤',
      category: category,
    );
  }

  /// Detect category from keywords
  static String _detectCategory(String transcript) {
    final lower = transcript.toLowerCase();

    final categoryKeywords = <String, List<String>>{
      'work': ['trabajo', 'reunión', 'proyecto', 'oficina', 'jefe', 'cliente', 'deadline'],
      'health': ['médico', 'doctor', 'salud', 'hospital', 'enfermo', 'medicina', 'cita médica'],
      'education': ['estudio', 'examen', 'clase', 'profesor', 'universidad', 'escuela', 'tarea'],
      'family': ['familia', 'hijo', 'hija', 'mamá', 'papá', 'hermano', 'hermana', 'abuelo'],
      'travel': ['viaje', 'vacaciones', 'vuelo', 'hotel', 'aeropuerto', 'destino'],
      'finance': ['dinero', 'banco', 'pagar', 'precio', 'cuenta', 'inversión', 'ahorro'],
      'technology': ['app', 'software', 'código', 'computadora', 'internet', 'programar'],
      'entertainment': ['película', 'serie', 'juego', 'música', 'concierto', 'netflix'],
      'sports': ['deporte', 'ejercicio', 'gym', 'fútbol', 'correr', 'entrenamiento'],
      'romantic': ['amor', 'pareja', 'cita', 'novio', 'novia', 'romántico'],
      'social': ['amigo', 'amiga', 'fiesta', 'salir', 'reunir', 'quedar'],
      'business': ['negocio', 'empresa', 'startup', 'emprender', 'vender', 'cliente'],
      'psychology': ['terapia', 'psicólogo', 'emociones', 'ansiedad', 'estrés', 'mental'],
    };

    for (final entry in categoryKeywords.entries) {
      if (entry.value.any((keyword) => lower.contains(keyword))) {
        return entry.key;
      }
    }

    return 'personal';
  }

  /// Generates a simple fallback title based on transcript content
  static Map<String, String> _generateFallbackTitle(String transcript) {
    final words = transcript.split(RegExp(r'\s+')).where((w) => w.length > 3).take(5).join(' ');
    final title = words.length > 40 ? '${words.substring(0, 37)}...' : words;

    String emoji = '🎤';
    final lower = transcript.toLowerCase();

    if (lower.contains('trabajo') || lower.contains('reunión') || lower.contains('proyecto')) {
      emoji = '💼';
    } else if (lower.contains('comida') || lower.contains('comer') || lower.contains('restaurante')) {
      emoji = '🍽️';
    } else if (lower.contains('viaje') || lower.contains('vacaciones') || lower.contains('viajar')) {
      emoji = '✈️';
    } else if (lower.contains('música') || lower.contains('canción') || lower.contains('concert')) {
      emoji = '🎵';
    } else if (lower.contains('deporte') || lower.contains('ejercicio') || lower.contains('gym')) {
      emoji = '🏃';
    } else if (lower.contains('familia') || lower.contains('hijo') || lower.contains('mamá')) {
      emoji = '👨‍👩‍👧';
    } else if (lower.contains('amor') || lower.contains('romántic') || lower.contains('cita')) {
      emoji = '❤️';
    } else if (lower.contains('estudio') || lower.contains('examen') || lower.contains('clase')) {
      emoji = '📚';
    } else if (lower.contains('salud') || lower.contains('médico') || lower.contains('doctor')) {
      emoji = '🏥';
    } else if (lower.contains('dinero') || lower.contains('compra') || lower.contains('precio')) {
      emoji = '💰';
    }

    return {
      'title': title.isNotEmpty ? title : 'Conversación',
      'emoji': emoji,
    };
  }

  /// Generates a brief summary of the conversation
  static Future<String?> generateSummary(List<TranscriptSegment> segments) async {
    final apiKey = Env.openAIAPIKey;
    if (apiKey == null || apiKey.isEmpty || segments.isEmpty) {
      return null;
    }

    final transcript = segments.map((s) => s.text).join('\n').trim();
    if (transcript.length < 50) return null;

    try {
      final response = await http
          .post(
            Uri.parse(_openAIEndpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode({
              'model': _model,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      'Resume la siguiente conversación en 2-3 oraciones. Sé conciso y captura los puntos principales.'
                },
                {
                  'role': 'user',
                  'content': transcript.substring(0, min(6000, transcript.length))
                }
              ],
              'max_tokens': 200,
              'temperature': 0.5,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return data['choices']?[0]?['message']?['content'] as String?;
      }
    } catch (e) {
      debugPrint('[ConversationProcessor] Error generating summary: $e');
    }

    return null;
  }
}
