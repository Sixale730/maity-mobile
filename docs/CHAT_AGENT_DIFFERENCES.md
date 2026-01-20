# Diferencias del Agente de Chat: Accounting vs OMI

## Resumen Ejecutivo

El chat de `C:\accounting` funciona correctamente porque tiene:
1. **17 herramientas especializadas** vs 3 básicas en OMI
2. **System prompt detallado** con capacidades claras
3. **Loop de function calling robusto** con manejo de errores
4. **Provider Flutter completo** con estados bien manejados

---

## 1. BACKEND - DEFINICIÓN DE TOOLS

### Accounting (`C:\accounting\app\api\chat\route.ts`)

**17 herramientas en 4 categorías:**

```typescript
// FINANZAS (7 tools)
1. consultar_gastos - Filtrar gastos por fecha/categoría/monto
2. consultar_saldos - Saldos de cuentas bancarias
3. consultar_facturas - CFDIs emitidos/recibidos
4. resumen_financiero - Resumen mensual completo
5. consultar_viajes - Ver viajes de trabajo
6. crear_viaje - Crear nuevo viaje
7. editar_viaje - Editar viaje existente

// GASTOS (1 tool)
8. crear_gasto - Registrar gasto con viaje

// CALENDARIO (3 tools)
9. consultar_calendario - Eventos Google Calendar
10. crear_evento_calendario - Crear evento
11. eliminar_evento_calendario - Eliminar evento

// CAJAS CHICAS (2 tools)
12. consultar_cajas_chicas - Ver cajas y saldos
13. crear_movimiento_caja_chica - Ingreso/retiro

// MARKETING (4 tools)
14. crear_publicacion - Post para redes sociales
15. crear_blog - Blog para WordPress
16. consultar_publicaciones - Ver publicaciones
17. consultar_blogs - Ver blogs
```

### OMI (`C:\OMI\api\routers\messages.py`)

**Solo 3 herramientas básicas:**

```python
1. buscar_conversaciones - Por rango de fechas
2. obtener_conversacion - Por ID
3. buscar_semantico - Búsqueda semántica
```

**Problema:** El chat no puede hacer nada útil más allá de buscar conversaciones.

---

## 2. SYSTEM PROMPT

### Accounting (Detallado)
```
Eres Maity, un asistente empresarial inteligente.

CAPACIDADES:
- Finanzas: Gastos, facturas, viajes, cajas chicas
- Marketing: Publicaciones en redes, blogs
- Calendario: Eventos Google Calendar

FECHA ACTUAL: {fecha en Mexico City}

REGLAS:
- Responde en español
- Sé conciso y amigable
- Formatea montos como MXN
- Cuando crees contenido, confirma al usuario
```

### OMI (Genérico)
```
Eres Maity, un asistente personal inteligente.

Tienes acceso a las conversaciones del usuario
grabadas con su wearable OMI.

Puedes:
- Buscar conversaciones por fecha
- Obtener detalles de una conversación
- Hacer búsquedas semánticas
```

**Problema:** El prompt no le da al modelo suficiente contexto ni guía de comportamiento.

---

## 3. LOOP DE FUNCTION CALLING

### Accounting (Robusto)
```typescript
// Líneas 1313-1354
while (assistantMessage.tool_calls && assistantMessage.tool_calls.length > 0) {
  const toolCalls = assistantMessage.tool_calls.filter(
    (tc) => tc.type === 'function'
  );

  console.log('[CHAT] Tool calls:', toolCalls.map(tc => tc.function.name));

  // Agregar mensaje del asistente con tool_calls
  openaiMessages.push(assistantMessage);

  // Ejecutar cada tool y agregar resultados
  for (const toolCall of toolCalls) {
    const args = JSON.parse(toolCall.function.arguments);
    const result = await ejecutarTool(toolCall.function.name, args, userId);

    openaiMessages.push({
      role: 'tool',
      tool_call_id: toolCall.id,
      content: result,
    });
  }

  // Obtener siguiente respuesta
  response = await openai.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: openaiMessages,
    tools: tools,
    tool_choice: 'auto',
  });

  assistantMessage = response.choices[0].message;
}
```

### OMI (Más Simple)
```python
# Líneas 317-395
for iteration in range(5):  # Máximo 5 iteraciones
    response = await client.chat.completions.create(
        model="gpt-4o-mini",
        messages=messages,
        tools=tools,
        tool_choice="auto"
    )

    message = response.choices[0].message

    if not message.tool_calls:
        break  # Respuesta final

    messages.append(message)

    for tool_call in message.tool_calls:
        result = await ejecutar_tool(tool_call.function.name,
                                     json.loads(tool_call.function.arguments),
                                     user_id)
        messages.append({
            "role": "tool",
            "tool_call_id": tool_call.id,
            "content": result
        })
```

**Diferencia:** El loop de OMI es similar pero el problema está en las tools disponibles.

---

## 4. EJECUCIÓN DE TOOLS

### Accounting (Completo)
```typescript
async function ejecutarTool(
  toolName: string,
  args: Record<string, unknown>,
  userId: string
): Promise<string> {
  try {
    switch (toolName) {
      case 'consultar_gastos':
        return await consultarGastos(userId, args);
      case 'consultar_saldos':
        return await consultarSaldos(userId);
      // ... 15 casos más
      default:
        return JSON.stringify({ error: `Tool ${toolName} no implementada` });
    }
  } catch (error) {
    console.error(`[CHAT] Error ejecutando ${toolName}:`, error);
    return JSON.stringify({
      error: `Error al ejecutar ${toolName}: ${error.message}`
    });
  }
}
```

### OMI (Básico)
```python
async def ejecutar_tool(tool_name: str, args: dict, user_id: str) -> str:
    try:
        if tool_name == "buscar_conversaciones":
            return await buscar_conversaciones(user_id, args)
        elif tool_name == "obtener_conversacion":
            return await obtener_conversacion(user_id, args)
        elif tool_name == "buscar_semantico":
            return await buscar_semantico(user_id, args)
        else:
            return json.dumps({"error": f"Tool {tool_name} no implementada"})
    except Exception as e:
        return json.dumps({"error": str(e)})
```

---

## 5. FLUTTER PROVIDER

### Accounting (`C:\accounting\mobile\lib\providers\chat_provider.dart`)

```dart
class ChatProvider extends ChangeNotifier {
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isRecording = false;
  bool _isTranscribing = false;
  String? _lastUserMessage;

  // Métodos completos
  void initChat()                              // Mensaje bienvenida personalizado
  Future<void> sendMessage(String, userId)    // Con retry automático
  void clearChat()
  Future<void> retry(userId)                   // Reintentar último mensaje

  // Audio input integrado
  Future<bool> startRecording()
  Future<void> stopRecordingAndSend(userId)
  Future<void> cancelRecording()
}
```

### OMI (`C:\OMI\lib\providers\message_provider.dart`)

```dart
class MessageProvider extends ChangeNotifier {
  List<ServerMessage> messages = [];
  bool sendingMessage = false;
  bool showTypingIndicator = false;

  // Métodos limitados
  // No tiene retry
  // No tiene manejo de audio
  // No tiene mensaje de bienvenida
}
```

**Diferencias clave:**
- Accounting tiene mensaje de bienvenida personalizado
- Accounting tiene retry de mensajes
- Accounting tiene grabación de audio integrada
- Accounting tiene quick actions

---

## 6. UI DEL CHAT

### Accounting (`C:\accounting\mobile\lib\screens\chat\chat_screen.dart`)

```dart
// 506 líneas con:
- Mensaje de bienvenida: "¡Hola! Soy Conta, tu asistente financiero..."
- Quick Actions (4 chips):
  - "Ver mis gastos"
  - "Resumen del mes"
  - "Saldos de cuentas"
  - "Crear un viaje"
- Grabación de audio con indicador visual
- Transcripción con Whisper
- Menu para limpiar chat
- Scroll automático
```

### OMI (`C:\OMI\lib\pages\chat\page.dart`)

```dart
// UI más básica:
- Sin mensaje de bienvenida
- Sin quick actions
- Sin grabación de audio nativa (usa componente externo)
- Sin retry de mensajes
```

---

## 7. SERVICIO DE CHAT

### Accounting (`C:\accounting\mobile\lib\services\chat_service.dart`)

```dart
class ChatService {
  static const String _baseUrl = 'https://erp.maity.com.mx';

  Future<String> transcribeAudio(String filePath) async {
    // Multipart upload a /api/chat/transcribe
    // Usa Whisper de OpenAI
  }

  Future<String> sendMessage({
    required String userId,
    required List<ChatMessage> messages,
  }) async {
    // POST a /api/chat
    // Envía historial completo
    // Retorna respuesta del asistente
  }
}
```

### OMI (`C:\OMI\lib\backend\http\api\messages.dart`)

```dart
Stream<ServerMessageChunk> sendMessageStreamServer(...) {
  // Streaming SSE
  // Parsing de chunks: think, data, done, error
  // Más complejo pero menos robusto
}
```

---

## 8. HISTORIAL DE MENSAJES

### Accounting
- Almacena en localStorage (web) y memoria (mobile)
- Envía historial completo a cada request
- Mantiene contexto de conversación

### OMI
- Envía `messages` en el body
- Pero el backend lo recibe como `MessageRequest`
- El historial puede no procesarse correctamente

---

## 9. MODELO DE MENSAJE

### Accounting
```dart
class ChatMessage {
  final String id;
  final String content;
  final ChatRole role;  // user | assistant
  final DateTime timestamp;
  final bool isLoading;

  factory ChatMessage.user(String content)
  factory ChatMessage.assistant(String content)
  factory ChatMessage.loading()
}
```

### OMI
```dart
class ServerMessage {
  String id;
  DateTime createdAt;
  String text;
  MessageSender sender;  // ai | human
  MessageType type;      // text | day_summary
  String? appId;
  bool fromIntegration;
  List<MessageFile> files;
  List<MessageConversation> memories;  // Conversaciones referenciadas
  List<String> thinkings;              // Pasos de razonamiento
}
```

**Problema OMI:** El modelo es más complejo pero `memories` no se popula correctamente.

---

## 10. PROBLEMAS ESPECÍFICOS DE OMI

### A. El chat responde "lo mismo"
**Causa:** Solo tiene 3 tools básicas, sin acceso real a datos útiles.

### B. No tiene acceso a memorias
**Causa:** Las tools solo hacen queries básicos, no hay integración con el contexto del usuario.

### C. Respuestas genéricas
**Causa:** System prompt muy vago, no guía al modelo.

---

## 11. RECOMENDACIONES PARA ARREGLAR OMI

### Paso 1: Expandir Tools
Agregar herramientas útiles como:
- `resumen_dia` - Resumen de conversaciones del día
- `buscar_por_tema` - Buscar por categoría
- `obtener_action_items` - Items pendientes
- `buscar_por_persona` - Menciones de personas
- `estadisticas_uso` - Métricas del usuario

### Paso 2: Mejorar System Prompt
```
Eres Maity, el asistente personal del usuario conectado a su wearable OMI.

CAPACIDADES:
- Buscar y resumir conversaciones
- Encontrar información específica en el historial
- Identificar temas recurrentes
- Listar tareas pendientes (action items)
- Generar estadísticas de uso

REGLAS:
- Responde en español
- Sé conciso y útil
- Cuando no encuentres información, sugiere cómo buscarla
- Cita las conversaciones relevantes
```

### Paso 3: Mejorar Provider Flutter
- Agregar mensaje de bienvenida
- Agregar quick actions
- Agregar retry de mensajes
- Mejorar manejo de errores

### Paso 4: Verificar Historial de Mensajes
Asegurar que el historial se envíe y procese correctamente.

---

## ARCHIVOS CLAVE PARA MODIFICAR

### Backend
- `C:\OMI\api\routers\messages.py` - Agregar tools y mejorar prompt

### Flutter
- `C:\OMI\lib\providers\message_provider.dart` - Agregar funcionalidad
- `C:\OMI\lib\pages\chat\page.dart` - Mejorar UI

---

## Plan de Implementación

1. **Fase 1: Backend** - Agregar más tools al chat
2. **Fase 2: System Prompt** - Mejorar instrucciones del agente
3. **Fase 3: Flutter Provider** - Agregar retry y bienvenida
4. **Fase 4: UI** - Quick actions y mejoras visuales

---

*Documento generado comparando C:\accounting y C:\OMI*
