# Maity - Asistente de IA con Wearable

## Descripcion
App Flutter que se conecta a un dispositivo wearable OMI via Bluetooth, transcribe conversaciones en tiempo real y genera analisis con IA.

**Soporte**: julio.gonzalez@maity.com.mx

## Arquitectura
```
Flutter App → Vercel Backend (FastAPI) → Supabase (PostgreSQL + pgvector)
                    ↓
               OpenAI (analisis + embeddings)
```

## Stack
- Frontend: Flutter (iOS, Android, Desktop)
- Backend: Vercel Serverless (Python/FastAPI)
- Database: Supabase PostgreSQL + pgvector
- AI: OpenAI (GPT-4o-mini, text-embedding-3-small)
- Audio: Deepgram (transcripcion), Opus codec
- Analytics: Mixpanel, Firebase Analytics/Crashlytics

## Supabase Configuration
- URL: `https://nhlrtflkxoojvhbyocet.supabase.co`
- Schema: `maity` (shared with web platform)
- pgvector: v0.8.0 (1536 dimensions for text-embedding-3-small)
- Tables: `omi_conversations`, `omi_transcript_segments`, `omi_memories`, `voice_profiles`, `user_feedback`
- RLS: Todas las tablas usan policies basadas en `auth.uid() = auth_id`

## Database Schema

### maity.users
- `id` (UUID PK), `auth_id` (UUID FK auth.users), `email`, `name`
- Trigger `handle_new_auth_user()` crea registro en signup

### maity.omi_conversations
Conversaciones con embedding vectorial:
- `id`, `user_id` (FK users), `title`, `overview`, `emoji`, `category`
- `action_items`, `events` (JSONB), `transcript_text`
- `embedding` (vector(1536)), `words_count`, `duration_seconds`
- Indices HNSW para busqueda vectorial

### maity.omi_transcript_segments
- `id`, `conversation_id` (FK), `user_id`, `text`, `speaker`, `speaker_id`, `is_user`
- `start_time`, `end_time`, `embedding` (vector(1536))

### maity.voice_profiles
- `id`, `user_id` (UNIQUE), `auth_id`, `embedding` (vector(192) ECAPA-TDNN)
- `enrollment_duration_seconds`, `samples_count`, `is_active`

### maity.omi_memories
- `id`, `user_id`, `auth_id`, `conversation_id` (nullable FK)
- `content`, `category` ('interesting'|'system'|'manual'), `reviewed`, `user_review`
- `manually_added`, `edited`, `deleted`, `visibility`, `is_locked`
- `embedding` (vector(1536))

### maity.user_feedback
- `id`, `user_id`, `auth_id`, `feedback_type` ('comment'|'bug'|'suggestion')
- `message`, `app_version`, `device_info`, `status`, `created_at`

### RPC Functions
- `search_omi_conversations`, `search_omi_segments`, `get_omi_conversation_with_segments`
- `get_voice_profile`, `search_omi_memories`, `get_pending_memories`

## Archivos Clave

### Providers
- `auth_provider.dart` - Autenticacion Supabase
- `conversation_provider.dart` - Estado conversaciones + busqueda semantica
- `capture_provider.dart` - Grabación, transcripción, guardado
- `usage_provider.dart` - Estadísticas de uso
- `memories_provider.dart` - CRUD memorias + revisión

### Services
- `supabase_auth_service.dart` - Auth Supabase (Google Sign-In)
- `maity_api_service.dart` - API backend
- `omi_supabase_service.dart` - Operaciones Supabase
- `voice_profile_service.dart` - Enrollment y verificación de voz
- `feedback_service.dart` - Feedback de usuarios

### Otros
- `lib/backend/http/shared.dart` - Cliente HTTP con auth centralizada
- `lib/backend/schema/` - Modelos de datos
- `lib/pages/home/page.dart` - Página principal

## Navegación de la App

| Índice | Página | Icono | Descripción |
|--------|--------|-------|-------------|
| 0 | ConversationsPage | House | Lista de conversaciones |
| 1 | ActionItemsPage | ListCheck | Tareas / To-Do's |
| 2 | MemoriesPage | Lightbulb | Memorias extraídas |
| 3 | UsagePage | ChartLine | Estadísticas (Insights) |

## Filtros de Conversaciones (ConversationsPage)
`lib/pages/conversations/conversations_page.dart`

### SearchWidget Filtros
La barra de búsqueda incluye varios filtros (iconos a la derecha):

| Filtro | Icono | Descripción |
|--------|-------|-------------|
| Búsqueda semántica | psychology/text_fields | Toggle entre búsqueda semántica (AI) y texto |
| Filtro por fecha | calendarDays | Seleccionar fecha específica |
| Filtro conversaciones cortas | clock | Filtrar por duración mínima |

### Short Conversation Filter
Permite ocultar conversaciones cortas según un umbral configurable.

**Archivos**:
- `lib/pages/settings/short_conversation_dialog.dart` - Dialog de configuración
- `lib/pages/conversations/widgets/search_widget.dart` - Botón de filtro
- `lib/providers/conversation_provider.dart` - Lógica de filtrado
- `lib/backend/preferences.dart` - Persistencia del setting

**Opciones de umbral**:
- 0 segundos (mostrar todas)
- 30 segundos
- 60 segundos (default)
- 120 segundos (2 min)
- 300 segundos (5 min)

**Settings persistidos**:
- `showShortConversations` (bool) - Si mostrar conversaciones cortas
- `shortConversationThreshold` (int) - Umbral en segundos

## Página de Tareas (ActionItemsPage)
`lib/pages/action_items/action_items_page.dart`

### Arquitectura
Action items se extraen automáticamente de conversaciones por OpenAI y se guardan en `omi_conversations.action_items` (JSONB).

```
Conversación → OpenAI extrae → action_items[] en omi_conversations
                                       ↓
Backend: GET /v1/action-items/from-conversations → Flatten + metadata
                                       ↓
Flutter: ActionItemsProvider → ActionItemsPage
```

### Tabs
| Tab | Descripción |
|-----|-------------|
| To Do | Items no completados (últimos 3 días) |
| Done | Items completados |
| Old | Items no completados (más de 3 días) |

### ID Format
`{conversation_id}_{index}` - Ejemplo: `abc-123_0`

### Endpoints Backend
| Endpoint | Método | Descripción |
|----------|--------|-------------|
| `/v1/action-items/from-conversations` | GET | Lista todos los action items |
| `/v1/action-items/{id}` | PATCH | Actualizar (completed, description) |
| `/v1/action-items/{id}` | DELETE | Eliminar action item |

### Archivos
- **Backend**: `api/routers/action_items.py`
- **Flutter API**: `lib/backend/http/api/action_items.dart`
- **Provider**: `lib/providers/action_items_provider.dart`
- **Page**: `lib/pages/action_items/action_items_page.dart`
- **Schema**: `lib/backend/schema/action_item.dart`

## Página de Insights (UsagePage)
`lib/pages/settings/usage_page.dart`

### 5 Métricas de Uso
| Métrica | Icono | Color | Descripción |
|---------|-------|-------|-------------|
| Listening | Microphone | Azul | Tiempo total de escucha (minutos) |
| Understanding | Comments | Verde | Palabras transcritas |
| Providing | WandMagicSparkles | Naranja | Insights (action_items + events) |
| Conversations | Message | Púrpura | Conversaciones grabadas |
| Memories | Lightbulb | Rosa | Memorias extraídas |

### Flujo de Datos (Backend → Flutter)
1. `MaityApiService.getMetrics(userId, period)` → `/v1/users/{id}/metrics`
2. Backend query `omi_conversations` + `omi_memories`
3. Respuesta incluye:
   - `stats`: transcription_seconds, words_transcribed, insights_gained, conversations_count, memories_count
   - `history`: datos diarios con insights y memories por fecha

### Archivos
- **Backend**: `api/routers/metrics.py`, `api/services/supabase_client.py`, `api/models/metrics.py`
- **Flutter**: `lib/providers/usage_provider.dart`, `lib/models/user_usage.dart`, `lib/services/maity_api_service.dart`

## Página de Detalle de Conversación
`lib/pages/conversation_detail/page.dart`

**Tabs**: Transcription, Summary, Action Items (localizados)
**AppBar**: Botón búsqueda (solo en Transcription/Summary), Menú con "Eliminar"

## Assets

**Logos**: `assets/images/` - `app_launcher_icon.png`, `maity_launcher_icon.png` (rosa #F93A6E), `maity_icon.png`, `maity_splash.png`

**Regenerar**:
- Launcher icon: `dart run flutter_launcher_icons`
- Splash screen: `dart run flutter_native_splash:create`

## Settings Drawer

**Perfiles de Usuario**:
- Developer (`*@asertio.mx`): Acceso completo (Storage, Developer Settings, Feedback Received)
- Usuario Final: Opciones reducidas

**Secciones**: Profile, Storage*, Device Settings, Share Maity, Send Feedback, Feedback Received*, Data & Privacy, Language, Developer Settings*, About Maity, Sign Out
(*solo Developer)

**Protección Guardados Duplicados**: Flag `_conversationFinalized` en CaptureProvider previene doble guardado.

## Internacionalización (i18n)

- **Archivos**: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- **Idiomas**: Inglés (en), Español (es)
- **Uso**: `AppLocalizations.of(context)!.keyName`
- **Agregar**: Editar .arb → `flutter gen-l10n`
- **Cambiar idioma runtime**: `MyApp.changeLocale('es')` (usa ValueNotifier)

**Páginas localizadas**: UsagePage, Onboarding, Settings, FindDevices, DataPrivacy, About, Storage, ConversationDetail, ActionItems, Chat, Memories, CommunicationFeedback.

**Fechas localizadas**: Usar `dateTimeFormat('MMM dd', date, locale: SharedPreferencesUtil().appLanguage)`

## Foreground Service Notification
Estados: waiting, device_connected, phone_mic, recording, processing, ready

Botones en estado `waiting`: Connect, Use Mic → navegan a FindDevicesPage

**Flujo**: CaptureProvider → `_updateForegroundNotification()` → FlutterForegroundTask → TaskHandler actualiza notificación

## Autenticacion (Supabase Auth)

### Flujo
1. Usuario toca "Continuar con Google"
2. `google_sign_in` obtiene idToken
3. `SupabaseAuthService.signInWithGoogleNative()` intercambia con Supabase
4. Trigger crea registro en `maity.users`
5. `fetchMaityUserId()` obtiene UUID de `maity.users`

### Tokens
- `getAccessToken()` obtiene/renueva JWT (auto-refresh 5 min antes de expirar)
- `getAuthHeader()` devuelve `Bearer <token>`
- Retry automático en 401

### IDs de Usuario
- `auth.users.id` - UUID Supabase Auth (en token como `sub`)
- `maity.users.id` - UUID tabla usuarios (usado para queries)

### Dominios Autenticados
`_isRequiredAuthCheck()` en `shared.dart`: `maity-mobile.vercel.app`

### Auto-detección Onboarding
Si `maityUserId != null` al login → usuario existe → marca `onboardingCompleted = true`

## Flujo de Datos

### Guardar Conversación
1. `LocalConversationsService.saveConversation()`
2. Guarda en Supabase via `OmiSupabaseService.storeConversation()`
3. Supabase retorna UUID → usa para objeto local
4. Si falla, genera UUID local como fallback

### Segmentos de Transcripción
- `onSegmentReceived()` recibe del STT
- `updateSegments()` detecta duplicados por ID
- IDs formato: `{timestamp}_{start}_{index}`
- `mergeConsecutiveSegmentsByTime()` fusiona (mismo speaker, gap < 3s)

### Carga en Detalle
Lista obtiene conversaciones SIN segmentos → `initConversation()` carga segmentos via `getConversation()`

### Busqueda Semantica
1. `semanticSearchConversations(query, userId)`
2. Backend genera embedding y busca por similitud coseno
3. Fallback a texto si falla

### Auto-guardado Custom STT
Timer de silencio (`conversationSilenceDuration`, default 120s) → `_onSilenceTimeout()` → guarda

### Optimizaciones Audio
- `WavBytes.asBytes()`: `setRange()` bulk copy
- `canDisplaySeconds()`: O(n) optimizado
- Buffer limit: 9600 frames (~10 min)
- `createWavFile()`: `.toList()` copia superficial

## Vercel Backend Endpoints

| Endpoint | Método | Descripción |
|----------|--------|-------------|
| `/v1/omi/conversations/store` | POST | Guardar con embeddings |
| `/v1/omi/conversations/search` | POST | Búsqueda semántica |
| `/v1/omi/conversations` | GET | Listar |
| `/v1/omi/conversations/{id}` | GET | Obtener con segmentos |
| `/v1/users/{id}/metrics` | GET | Métricas por periodo |
| `/v1/users/{id}/metrics/summary` | GET | Resumen métricas |
| `/v2/messages` | POST | Chat con function calling |
| `/v1/feedback/*` | * | Submit, list, my |
| `/v1/memories/*` | * | CRUD, extract, search, review |
| `/v1/voice/*` | * | Enroll, verify-speakers, status, delete |

## User Feedback System

**Arquitectura**: Flutter → Vercel `/v1/feedback/*` → Supabase `user_feedback`

**Tipos**: comment (💬), bug (🐛), suggestion (💡)

**Permisos**: Todos envían/ven propio, Developers ven todos

**Archivos**: `api/routers/feedback.py`, `lib/services/feedback_service.dart`, `lib/pages/settings/feedback_page.dart`

## Chat Agent (Maity)

**Arquitectura**: Flutter → Vercel `/v2/messages` → OpenAI (gpt-4o-mini + function calling) → Supabase

### Tools (8)
| Tool | Descripción |
|------|-------------|
| `buscar_conversaciones` | Por rango de fechas |
| `obtener_conversacion` | Detalles + transcripción |
| `buscar_semantico` | Por tema/contenido |
| `resumen_dia` | Resumen del día con métricas |
| `obtener_action_items` | Tareas pendientes |
| `buscar_por_categoria` | Filtrar por categoría |
| `estadisticas_uso` | Métricas por período |
| `feedback_comunicacion` | Análisis estilo comunicación |

### Quick Actions
Resumen de hoy, Mis pendientes, Mis estadísticas, Cómo me comunico

### Patrón de Respuesta
```python
{"success": True/False, "error": None/"mensaje", "data": {...}}
```

**Archivos**: `api/routers/messages.py`, `api/services/supabase_client.py`, `lib/pages/chat/page.dart`

## Analytics (Mixpanel)

**Configuración**: Token en `.env` → `MIXPANEL_PROJECT_TOKEN=<token>`

### Archivos
- `lib/utils/analytics/mixpanel.dart` - MixpanelManager singleton
- `lib/env/env.dart` - Variables de entorno (envied)

### Inicialización
Se inicializa en `main.dart` via `MixpanelManager.init()`. Solo se activa si el token está configurado.

### Plataformas
- **Mobile (iOS/Android)**: usa `mixpanel_flutter` (nativo)
- **Desktop**: usa `mixpanel_analytics` (HTTP)

### Uso
```dart
MixpanelManager().track('Event Name', properties: {'key': 'value'});
MixpanelManager().setUserProperty('Property', value);
```

### Métodos principales
| Método | Descripción |
|--------|-------------|
| `track(event, properties)` | Envía evento |
| `identify()` | Identifica usuario |
| `setUserProperty(key, value)` | Propiedad de usuario |
| `trackTestEvent()` | Evento de prueba (Debug) |

### Testing
En Developer Settings > Debug & Diagnostics hay un botón "Test Mixpanel" que envía un evento de prueba para verificar la conexión.

## Conexión Bluetooth (BLE)

### Archivos Clave
- `lib/services/devices/transports/ble_transport.dart` - Transporte BLE, conexión y escritura
- `lib/services/devices/discovery/bluetooth_discoverer.dart` - Escaneo y descubrimiento de dispositivos
- `lib/providers/device_provider.dart` - Estado de conexión y reconexión

### Mejoras Implementadas

#### allowLongWrite para datos grandes
Cuando los datos exceden el tamaño MTU (Maximum Transmission Unit), se usa `allowLongWrite: true` automáticamente:
```dart
final useAllowLongWrite = data.length > (_bleDevice.mtuNow - 3);
await characteristic.write(data, allowLongWrite: useAllowLongWrite);
```
- MTU incluye 3 bytes de overhead del protocolo ATT
- Crítico para firmware updates y transferencias de datos grandes

#### Timeout en espera de Bluetooth
Evita bloqueos indefinidos si Bluetooth está desactivado:
- Timeout de 10 segundos esperando que el adaptador se active
- Retorna gracefully si el timeout se alcanza

#### Delay de permisos en Android
Agrega un delay de 2 segundos después de que Bluetooth se activa en Android:
- Permite que los permisos se establezcan completamente
- Soluciona problema donde dispositivos no aparecían en primer escaneo

#### Exponential Backoff en Reconexión
Patrón de reintentos con incremento exponencial para reconexión eficiente:
- Delay inicial: 2 segundos
- Multiplicador: 1.5x
- Máximo delay: 60 segundos
- Límite de reintentos: 8

**Secuencia de delays**: 2s → 3s → 4.5s → 6.75s → 10.1s → 15.2s → 22.8s → 34.2s

#### Notificaciones de Conexión/Desconexión
El sistema notifica al usuario sobre cambios de estado de conexión:

**Conexión (`_onDeviceConnected`)**:
- Muestra notificación "Maity Connected" con el nombre del dispositivo
- Dispara analytics `MixpanelManager().deviceConnected()` en TODAS las conexiones (inicial y reconexiones)
- Notificación ID: 2

**Desconexión (`onDeviceDisconnected`)**:
- Timer de 5 segundos antes de mostrar notificación (permite reconexión rápida sin notificar)
- Mensaje indica que está intentando reconectar automáticamente
- Notificación ID: 1 (se limpia al reconectar)
- Analytics `MixpanelManager().deviceDisconnected()` inmediato

**Strings localizados**: `deviceConnectedTitle`, `deviceConnectedBody`, `deviceDisconnectedTitle`, `deviceDisconnectedBody`

## Speaker Verification

**Arquitectura**:
- Enrollment: Flutter → Vercel `/v1/voice/enroll` → Modal.com (ECAPA-TDNN) → Supabase
- Verificación: Conversación finaliza → extrae audio por speaker → compara con perfil

### Flujo Enrollment
1. Grabar 30+ segundos en Speech Profile
2. Validar: auth, duración 10-155s, mínimo 25 palabras
3. Enviar a Modal.com → guardar embedding

### Códigos Error
`AUTH_REQUIRED`, `ENROLLMENT_FAILED`, `ENROLLMENT_VERIFICATION_FAILED`, `TOO_SHORT`, `NO_SPEECH`, `MULTIPLE_SPEAKERS`

### Modal.com
- Modelo: speechbrain/spkrec-ecapa-voxceleb
- Deploy: `cd modal_functions && python -m modal deploy voice_embeddings.py`
- Env: `MODAL_VOICE_ENDPOINT_URL=https://divertido--maity-voice-embeddings`

### Verificación Automática
Al finalizar conversación: extrae audio por speaker → compara con embedding → re-etiqueta `is_user`
Threshold similitud: 0.75-0.80 (balanceado)

**Archivos**: `modal_functions/voice_embeddings.py`, `api/routers/voice_profiles.py`, `lib/services/voice_profile_service.dart`

## Feedback de Comunicación

**Arquitectura**: Conversación → Vercel `/v1/communication/analyze` → OpenAI → CommunicationFeedback

### Modelo
- `strengths`, `areas_to_improve` (máx 5 cada uno)
- `observations`: claridad, estructura, llamados a acción, objeciones
- `counters`: pero_count, filler_words, objections_received/made

### Muletillas Detectadas
"este", "o sea", "como que", "bueno", "entonces", "básicamente", "literalmente", "tipo", "digamos", "la verdad"

**Archivos**: `api/models/communication.py`, `api/services/communication_analyzer.py`, `lib/pages/conversation_detail/widgets.dart`

## Sistema de Memorias

**Arquitectura**: Conversación → `/v1/memories/extract` → OpenAI extrae 2-5 memorias → embeddings → Supabase

### Categorías
- `interesting`: Extraídas por IA
- `system`: Del sistema
- `manual`: Creadas por usuario

### Flujo Revisión
1. IA extrae memorias (`reviewed=false`)
2. Usuario ve banner en MemoriesPage
3. Swipe para aprobar/rechazar

### Archivos
**Backend**: `api/routers/memories.py`, `api/services/memory_extractor.py`, `api/models/memory.py`
**Flutter**: `lib/backend/http/api/memories.dart`, `lib/providers/memories_provider.dart`, `lib/pages/memories/`

## Backend (Monorepo)

Código en `C:\OMI\api\`:
- `index.py` - FastAPI entry point
- `routers/` - omi, metrics, feedback, memories, voice_profiles, messages
- `services/` - supabase_client, embeddings, memory_extractor, communication_analyzer
- `models/` - memory, communication

### Variables de Entorno (Vercel)
- `OPENAI_API_KEY`
- `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_JWT_SECRET`
- `MODAL_VOICE_ENDPOINT_URL`

### Variables de Entorno (Flutter .env)
- `MIXPANEL_PROJECT_TOKEN` - Token de Mixpanel para analytics
- `DEEPGRAM_API_KEY` - STT Deepgram
- `GOOGLE_CLIENT_ID` - Google Sign-In
- `SUPABASE_URL`, `SUPABASE_ANON_KEY` - Supabase client

## Patrón BuildContext Async

```dart
Future<void> myAsyncMethod() async {
  if (!mounted) return;
  final navigator = Navigator.of(context);  // Capturar ANTES
  await someAsyncOperation();
  if (!mounted) return;  // Verificar DESPUÉS
  navigator.push(...);  // Usar referencia capturada
}
```

**Reglas**: Verificar `mounted` antes/después de awaits, capturar Navigator/ScaffoldMessenger/Providers antes del await.

## Documentación Adicional

- `docs/CHAT_AGENT_DIFFERENCES.md` - Comparación chat agent
- `docs/google-sign-in-setup.md` - Google Sign-In setup
