# Maity - Asistente de IA con Wearable

## Descripcion
App Flutter que se conecta a un dispositivo wearable OMI via Bluetooth, transcribe conversaciones en tiempo real y genera analisis con IA.

## Objetivo Actual
Migrar de Firebase a Supabase completo (auth + PostgreSQL + pgvector) para:
- Guardar conversaciones en base de datos propia
- Implementar busqueda semantica con vectores
- Generar metricas y estadisticas de uso

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

## Supabase Configuration
- URL: `https://nhlrtflkxoojvhbyocet.supabase.co`
- Schema: `maity` (shared with web platform)
- pgvector: v0.8.0 (1536 dimensions for text-embedding-3-small)
- Tables: `maity.omi_conversations`, `maity.omi_transcript_segments`, `maity.voice_profiles`

## Database Schema

### maity.users
Usuarios de la plataforma (compartido con web):
- `id` (UUID) - Primary key
- `auth_id` (UUID) - FK a auth.users (Supabase Auth)
- `email`, `name` - Datos basicos del usuario
- Trigger `handle_new_auth_user()` crea automaticamente en signup

### maity.omi_conversations
Tabla principal para conversaciones del wearable con embedding vectorial:
- `id` (UUID) - Primary key
- `user_id` (UUID) - Referencia a maity.users.id
- `firebase_uid` (TEXT, nullable) - Legacy, ya no se usa
- `title`, `overview`, `emoji`, `category` - Datos estructurados del AI
- `action_items`, `events` (JSONB) - Items de accion y eventos
- `transcript_text` (TEXT) - Transcripcion completa
- `embedding` (vector(1536)) - Embedding para busqueda semantica
- `words_count`, `duration_seconds` - Metricas
- Indices HNSW para busqueda vectorial rapida
- RLS policies basadas en `auth.uid() = auth_id`

### maity.omi_transcript_segments
Segmentos individuales de transcripcion con embeddings granulares:
- `id` (UUID), `conversation_id` (UUID FK)
- `user_id` (UUID) - Referencia a maity.users.id
- `text`, `speaker`, `speaker_id`, `is_user`
- `start_time`, `end_time` - Timing del segmento
- `embedding` (vector(1536)) - Para busqueda granular

### maity.voice_profiles
Perfiles de voz para identificación del usuario (Speaker Verification):
- `id` (UUID) - Primary key
- `user_id` (UUID) - Referencia a maity.users.id (UNIQUE)
- `auth_id` (UUID) - FK a auth.users.id
- `embedding` (vector(192)) - Embedding ECAPA-TDNN para identificación de voz
- `enrollment_duration_seconds` (FLOAT) - Duración del audio de enrollment
- `samples_count` (INT) - Número de muestras usadas
- `is_active` (BOOLEAN) - Perfil activo
- Índice HNSW para búsqueda por similitud coseno

### RPC Functions
- `maity.search_omi_conversations(p_user_id, ...)` - Busqueda semantica de conversaciones
- `maity.search_omi_segments(p_user_id, ...)` - Busqueda semantica de segmentos
- `maity.get_omi_conversation_with_segments(p_user_id, ...)` - Obtener conversacion con segmentos
- `maity.get_voice_profile(p_user_id)` - Obtener perfil de voz del usuario

## Archivos Clave
- lib/providers/auth_provider.dart - Autenticacion con Supabase Auth
- lib/services/supabase_auth_service.dart - Servicio de auth Supabase (Google Sign-In nativo)
- lib/providers/conversation_provider.dart - Estado de conversaciones + busqueda semantica
- lib/providers/capture_provider.dart - Manejo de grabación, transcripción y guardado de conversaciones
- lib/providers/usage_provider.dart - Estadísticas de uso desde Supabase (metrics)
- lib/services/maity_api_service.dart - API backend (procesa y almacena en Supabase)
- lib/services/omi_supabase_service.dart - Servicio para operaciones Supabase
- lib/services/voice_profile_service.dart - Servicio para enrollment y verificación de voz
- lib/backend/http/shared.dart - Cliente HTTP con autenticacion centralizada
- lib/backend/schema/conversation.dart - Modelos de datos
- lib/pages/home/page.dart - Página principal con navegación inferior

## Navegación de la App
La app tiene 2 tabs en la barra de navegación inferior:

| Índice | Página | Icono | Descripción |
|--------|--------|-------|-------------|
| 0 | ConversationsPage | House | Lista de conversaciones grabadas |
| 1 | UsagePage | ChartLine | Estadísticas de uso (Insights) |

**Nota**: Los tabs de ActionItems, Memories y Apps fueron ocultados temporalmente.

## Assets y Splash Screen

### Imágenes de Logo
- `assets/images/maity_icon.png` - Logo original (1340×1345 px) usado para app icon
- `assets/images/maity_splash.png` - Logo para splash screen (1152×1152 px, logo ~600px centrado)

### Splash Screen (Android 12+)
Android 12+ aplica una máscara circular de 768px sobre el splash icon. Para evitar que los 6 círculos decorativos del logo se corten:

- `maity_splash.png` tiene el logo redimensionado a ~600px y centrado en canvas de 1152×1152
- Configurado en `pubspec.yaml` sección `flutter_native_splash`
- Regenerar con: `dart run flutter_native_splash:create`

Archivos generados automáticamente en `android/app/src/main/res/drawable-*/`:
- `splash.png` - Splash para Android <12
- `android12splash.png` - Splash para Android 12+

## Settings Drawer (Maity personalizado)
El drawer de configuración ha sido personalizado para Maity:

### Header
- Título "Settings" / "Ajustes"
- Email del usuario logueado (de SharedPreferencesUtil().email)

### Secciones

**Perfil y Dispositivo:**
- Profile - Configuración de perfil
- Storage - Sincronización de datos
- Device Settings - Configuración Bluetooth

**Compartir:**
- Share Maity → maity.com.mx

**Soporte (solo si Intercom habilitado):**
- Feedback / Bug
- Help Center

**Privacidad y Configuración:**
- Data & Privacy
- Language - Selector de idioma (es/en)
- Developer Settings
- About Maity

**Sesión:**
- Sign Out

**Removidos:**
- Chat Tools (herramientas de integración)
- Plan & Usage / Usage Insights (ya está en tab principal)
- Get Omi for Mac
- Referral Program

### Protección contra Guardados Duplicados
`CaptureProvider` tiene un flag `_conversationFinalized` que previene guardados duplicados cuando:
- `stopStreamRecording()` y `forceProcessingCurrentConversation()` se llaman en secuencia
- El flag se resetea en `_resetStateVariables()` para la siguiente conversación

## Internacionalización (i18n)
La app soporta múltiples idiomas usando Flutter's built-in localization:

### Archivos de Localización
- `lib/l10n/app_en.arb` - Diccionario inglés
- `lib/l10n/app_es.arb` - Diccionario español
- `lib/l10n/app_localizations.dart` - Clase generada

### Idiomas Soportados
- Inglés (`en`)
- Español (`es`)

### Uso en Código
```dart
import 'package:omi/l10n/app_localizations.dart';

// En un widget:
final l10n = AppLocalizations.of(context)!;
Text(l10n.insights) // "Insights" o "Estadísticas"
```

### Agregar Nuevas Traducciones
1. Agregar clave a `app_en.arb` con valor en inglés
2. Agregar misma clave a `app_es.arb` con traducción
3. Ejecutar `flutter gen-l10n` para regenerar

### Páginas Localizadas
- UsagePage (Insights) - Completamente localizada
- Onboarding pages - Completamente localizadas
- Settings drawer - Completamente localizado

## Autenticacion (Supabase Auth)

### Flujo de Autenticacion
1. Usuario toca "Continuar con Google"
2. `google_sign_in` obtiene idToken de Google
3. `SupabaseAuthService.signInWithGoogleNative()` intercambia con Supabase
4. Supabase valida → crea/actualiza `auth.users`
5. Trigger `handle_new_auth_user()` crea registro en `maity.users`
6. Flutter recibe session con accessToken
7. `SupabaseAuthService.fetchMaityUserId()` obtiene UUID de `maity.users`

### Tokens
- `SupabaseAuthService.getAccessToken()` obtiene/renueva token JWT
- Token se almacena en `SharedPreferencesUtil().authToken`
- `getAuthHeader()` en `shared.dart` devuelve `Bearer <token>`
- Auto-refresh 5 minutos antes de expirar

### IDs de Usuario
- `auth.users.id` - UUID de Supabase Auth (en token como `sub`)
- `maity.users.id` - UUID de la tabla de usuarios (usado para queries)
- `maity.users.auth_id` - FK a auth.users.id

### Dominios Autenticados
La funcion `_isRequiredAuthCheck()` en `shared.dart` determina que URLs requieren el header Authorization:
- `maity-mobile.vercel.app` (Backend Maity/Supabase - ACTIVO)
- `maity-backend.vercel.app` (Legacy, ya no se usa)

**Nota**: `API_BASE_URL` (api.omi.me) está deshabilitado porque usa Firebase Auth diferente.

### Retry de Token
`makeApiCall()` implementa retry automatico en caso de 401:
1. Detecta respuesta 401
2. Llama `SupabaseAuthService.getAccessToken()` para renovar token
3. Reintenta la peticion con nuevo token

### Auto-detección de Onboarding Completado
Al iniciar sesión, `AuthProvider` verifica si el usuario ya existe en `maity.users`:
- Si `maityUserId != null` → usuario existe → ya completó onboarding antes
- Automáticamente marca `SharedPreferencesUtil().onboardingCompleted = true`
- Funciona como fallback si SharedPreferences pierde el flag (reinstalación, error, etc.)
- La BD (`maity.users`) sirve como fuente de verdad para el estado de onboarding

**Ubicación**: `lib/providers/auth_provider.dart:60-65` y `:161-165`

## Flujo de Datos

### Guardar Conversacion (LocalConversationsService)
Cuando se finaliza una conversación con custom STT (Deepgram directo):

1. `LocalConversationsService.saveConversation()` se ejecuta
2. **PRIMERO** guarda en Supabase via `OmiSupabaseService.storeConversation()`
3. Supabase genera el UUID y lo retorna en `StoredConversationResponse.id`
4. Usa ese ID para crear el objeto `ServerConversation`
5. Guarda localmente en SharedPreferences con el MISMO ID

**Importante**: Este orden asegura que el ID local y el de Supabase sean idénticos.
Si Supabase falla, genera un UUID local como fallback.

### Segmentos de Transcripción
Los segmentos de transcripción se acumulan durante una conversación:

1. `CaptureProvider.onSegmentReceived()` recibe segmentos del servicio STT
2. `TranscriptSegment.updateSegments()` compara por ID para detectar duplicados
3. Segmentos con IDs nuevos se agregan a la lista

**Importante**: Los segmentos de Deepgram/Gemini Live necesitan un campo `id` único.
Los servicios STT (streaming y polling) generan IDs con formato: `{timestamp}_{start}_{index}`

### Guardar via MaityApiService (legacy)
1. MaityApiService.processConversation() procesa con OpenAI
2. Automaticamente llama OmiSupabaseService.storeConversation()
3. Vercel backend genera embeddings y guarda en Supabase

### Busqueda Semantica
1. ConversationProvider.semanticSearchConversations(query, userId: maityUserId)
2. OmiSupabaseService.searchConversations() llama a Vercel
3. Vercel genera embedding del query y busca por similitud coseno
4. Fallback automatico a busqueda de texto si falla

### Auto-guardado con Custom STT
Con custom STT (Deepgram directo), el guardado automático funciona así:

1. `CaptureProvider._resetSilenceTimer()` inicia timer al recibir segmentos
2. Timer se resetea con cada nuevo segmento
3. Si expira (N segundos sin segmentos), llama `_onSilenceTimeout()`
4. Esto ejecuta `_finalizeLocalConversation()` y guarda en Supabase

**Configuración**: `SharedPreferencesUtil().conversationSilenceDuration`
- Default: 120 segundos (2 minutos)
- -1 = Solo manual (sin auto-guardado)

**Nota**: OMI original usaba `conversation_timeout` parámetro enviado a api.omi.me,
pero con custom STT el timer es client-side.

### Fusión de Segmentos
Los segmentos de transcripción se fusionan automáticamente:

1. `TranscriptSegment.mergeConsecutiveSegmentsByTime()` fusiona segmentos
2. Condiciones: mismo speaker, mismo isUser, gap < 3 segundos
3. Se llama en `_processNewSegmentReceived()` después de agregar segmentos

Esto evita que Deepgram fragmente segmentos por pausas naturales del habla.

### Optimizaciones de Audio y Transcripción

Optimizaciones de rendimiento implementadas en el procesamiento de audio:

**WavBytes.asBytes()** (`wav_bytes.dart:76-77`)
- Usa `setRange()` para copia bulk en lugar de loop byte a byte
- Significativamente más rápido para buffers grandes de audio

**TranscriptSegment.canDisplaySeconds()** (`transcript_segment.dart:241-252`)
- Reducida de O(n²) a O(n)
- Solo verifica solapamiento con el segmento siguiente (suficiente para timestamps ordenados)

**WavBytesUtil Buffer Limit** (`wav_bytes.dart:91,130-133`)
- `_maxFrames = 9600` (~10 minutos a 16 frames/segundo)
- Previene memory leak en grabaciones largas
- Buffer circular: elimina frames más antiguos al exceder límite

**createWavFile()** (`wav_bytes.dart:311-330`)
- Usa `.toList()` (copia superficial) en lugar de `List.from()` (copia profunda)
- Los inner lists de frames no se modifican, copia superficial es suficiente

**convertToLittleEndianBytes()** (`wav_bytes.dart:381-391`)
- Usa índice acumulativo (`offset += 2`) en lugar de multiplicación (`i * 2`)
- Micro-optimización que evita multiplicación en cada iteración

### Speech Profile con Custom STT
Speech Profile ahora funciona con custom STT (Deepgram):

- `SocketServicePool.speechProfile()` usa `customSttConfig` si está habilitado
- Permite entrenar perfil de voz cuando api.omi.me está deshabilitado
- Ubicación: `lib/services/sockets.dart`

## Pendiente
1. ~~Crear proyecto Supabase con pgvector~~ DONE
2. ~~Crear backend en Vercel~~ DONE (endpoints OMI)
3. ~~Integrar supabase_flutter~~ DONE
4. ~~Migrar auth de Firebase a Supabase~~ DONE (Google Sign-In)
5. ~~Implementar guardado de conversaciones~~ DONE
6. ~~Agregar busqueda semantica~~ DONE
7. ~~Dashboard de metricas~~ DONE
8. UI para mostrar resultados de busqueda semantica
9. ~~Limpiar código legacy de Firebase Auth~~ DONE (eliminado firebase_options.dart y referencias en setup scripts)

## Vercel Backend Endpoints (OMI)
| Endpoint | Metodo | Descripcion |
|----------|--------|-------------|
| `/v1/omi/conversations/store` | POST | Guarda conversacion con embeddings |
| `/v1/omi/conversations/search` | POST | Busqueda semantica |
| `/v1/omi/conversations` | GET | Listar conversaciones |
| `/v1/omi/conversations/{id}` | GET | Obtener conversacion con segmentos |
| `/v1/users/{user_id}/metrics` | GET | Metricas de uso por periodo (Supabase) |
| `/v1/users/{user_id}/metrics/summary` | GET | Resumen de metricas (today, monthly, all-time) |

## Backend (Monorepo)
Codigo en `C:\OMI\api\` (misma carpeta que Flutter app):
- `api/index.py` - FastAPI entry point
- `api/routers/omi.py` - Endpoints OMI para Supabase
- `api/routers/metrics.py` - Endpoints de métricas de uso (Supabase)
- `api/services/supabase_client.py` - Cliente Supabase con service_role
- `api/services/embeddings.py` - Generacion de embeddings OpenAI
- `vercel.json` - Configuracion de deploy Vercel
- `requirements.txt` - Dependencias Python

Variables de entorno requeridas (configurar en Vercel):
- `OPENAI_API_KEY` - Para embeddings y procesamiento
- `SUPABASE_URL` - URL del proyecto Supabase
- `SUPABASE_SERVICE_KEY` - Service role key (NO anon key)
- `SUPABASE_JWT_SECRET` - JWT secret para validar tokens (desde Supabase Dashboard > Settings > API)
- `MODAL_VOICE_ENDPOINT_URL` - URL del servicio Modal.com para voice embeddings

## Speaker Verification (Identificación de Voz)

Sistema para identificar al usuario por huella de voz usando embeddings ECAPA-TDNN (192 dimensiones).

### Arquitectura
```
ENROLLMENT:
Flutter (Speech Profile UI) → Vercel (/v1/voice/enroll) → Modal.com (ECAPA-TDNN) → Supabase (voice_profiles)

VERIFICACIÓN AUTOMÁTICA:
Conversación finaliza → CaptureProvider extrae audio por speaker → Vercel → Modal → Comparar con perfil → Re-etiquetar is_user
```

### Flujo de Enrollment
1. Usuario va a Speech Profile y graba 30+ segundos
2. `SpeechProfileProvider.finalize()` valida:
   - `maityUserId` no es null (error: `AUTH_REQUIRED`)
   - Duración entre 10-155 segundos
   - Mínimo 25 palabras detectadas
3. Crea archivo WAV con `audioStorage.createWavFile()`
4. `VoiceProfileService.enrollVoiceProfile()` valida:
   - Archivo existe y tiene >1000 bytes
   - Token de autenticación válido
5. Envía audio a Vercel → Modal.com (ECAPA-TDNN)
6. Verifica post-enrollment con `getProfileStatus()` (error: `ENROLLMENT_VERIFICATION_FAILED`)
7. Si todo OK, marca `profileCompleted = true`

### Códigos de Error de Enrollment
| Código | Descripción | Mensaje al Usuario |
|--------|-------------|-------------------|
| `AUTH_REQUIRED` | `maityUserId` es null | "You need to be signed in to create your voice profile" |
| `ENROLLMENT_FAILED` | Falló envío al backend | "Could not save your voice profile. Please check your internet connection" |
| `ENROLLMENT_VERIFICATION_FAILED` | Perfil no encontrado post-save | "Your voice profile was not saved correctly. Please try again" |
| `TOO_SHORT` | Menos de 25 palabras | "There is not enough speech detected" |
| `NO_SPEECH` | Duración inválida | "We could not detect any speech" |
| `MULTIPLE_SPEAKERS` | Más de un speaker detectado | "It seems like there are multiple speakers" |

**Nota**: Todos los errores se manejan tanto en la página de onboarding (`speech_profile_widget.dart`) como en la página de settings (`speech_profile/page.dart`).

### Modal.com (Servicio ML)
Archivo: `modal_functions/voice_embeddings.py`
- Modelo: speechbrain/spkrec-ecapa-voxceleb (ECAPA-TDNN)
- GPU: T4 (económica)
- Endpoints HTTP desplegados:
  - `https://divertido--maity-voice-embeddings-extract-embedding-http.modal.run`
  - `https://divertido--maity-voice-embeddings-verify-speakers-http.modal.run`
  - `https://divertido--maity-voice-embeddings-health.modal.run`

Deploy: `cd modal_functions && python -m modal deploy voice_embeddings.py`

Variable de entorno Vercel:
```
MODAL_VOICE_ENDPOINT_URL=https://divertido--maity-voice-embeddings
```

### Endpoints Voice Profiles
| Endpoint | Método | Descripción |
|----------|--------|-------------|
| `/v1/voice/enroll` | POST | Enrollment: audio WAV → embedding → Supabase |
| `/v1/voice/verify-speakers` | POST | Verificar speakers contra perfil |
| `/v1/voice/status` | GET | Estado del perfil de voz |
| `/v1/voice/profile` | DELETE | Eliminar perfil |

### Archivos del Sistema
- `modal_functions/voice_embeddings.py` - Servicio Modal.com (ECAPA-TDNN)
- `api/routers/voice_profiles.py` - Endpoints Vercel
- `lib/services/voice_profile_service.dart` - Cliente Flutter
- `lib/providers/speech_profile_provider.dart` - Integra enrollment
- `lib/providers/capture_provider.dart` - Audio buffer + verificación automática
- `lib/utils/audio/wav_bytes.dart` - Extracción de audio por timestamps

### Estado Actual
- [x] Enrollment de perfil de voz (funcional)
- [x] Backend Vercel con endpoints
- [x] Modal.com con ECAPA-TDNN desplegado
- [x] Tabla voice_profiles en Supabase
- [x] Buffer de audio en CaptureProvider
- [x] Verificación automática al finalizar conversación

### Flujo de Verificación Automática
Cuando una conversación finaliza con custom STT:

1. `_finalizeLocalConversation()` se ejecuta
2. Llama `_verifySpeakersWithVoiceProfile(userId)`
3. Verifica si usuario tiene perfil de voz (`VoiceProfileService.getProfileStatus()`)
4. Si hay múltiples speakers, extrae audio del segmento más largo de cada uno
5. Usa `_audioBuffer.extractAudioRangeAsBase64()` para extraer audio por timestamps
6. Llama `VoiceProfileService.verifySpeakers()` con los audios
7. Backend Vercel → Modal.com compara contra embedding del usuario
8. Re-etiqueta `is_user` en segmentos basado en similitud coseno (threshold: 0.75)

### Umbral de Similitud
- 0.65-0.70: Muy permisivo (más falsos positivos)
- 0.75-0.80: Balanceado (recomendado)
- 0.85-0.90: Estricto (más falsos negativos)

## Feedback de Comunicación

Sistema de análisis de comunicación que proporciona feedback cualitativo y cuantitativo sobre el estilo de comunicación del usuario.

### Arquitectura
```
Conversación → Vercel (/v1/communication/analyze) → OpenAI GPT-4o-mini → CommunicationFeedback
```

### Modelo de Datos

**CommunicationFeedback** - Feedback completo de comunicación:
- `strengths`: Lista de fortalezas (máx 5)
- `areas_to_improve`: Lista de áreas de mejora (máx 5)
- `observations`: Observaciones por categoría (claridad, estructura, llamados a acción, objeciones)
- `summary`: Resumen del estilo de comunicación
- `counters`: Métricas cuantitativas (opcional)

**CommunicationCounters** - Métricas cuantitativas:
- `pero_count`: Número de veces que el usuario dice "pero"
- `objection_words`: Frecuencia de palabras de objeción `{"pero": N, "sin embargo": N, "aunque": N}`
- `objections_received`: Lista de objeciones que el otro hace al usuario (máx 5)
- `objections_made`: Lista de objeciones que el usuario hace (máx 5)
- `filler_words`: Frecuencia de muletillas `{"este": N, "o sea": N, "bueno": N, "entonces": N}`

### Muletillas Detectadas
- "este" / "este..."
- "o sea"
- "como que"
- "bueno"
- "entonces"
- "básicamente"
- "literalmente"
- "tipo" / "tipo que"
- "digamos"
- "la verdad"

### Archivos del Sistema
- `api/models/communication.py` - Modelos Pydantic (CommunicationFeedback, CommunicationCounters)
- `api/services/communication_analyzer.py` - Servicio de análisis con OpenAI
- `lib/models/communication_feedback.dart` - Modelos Dart
- `lib/pages/conversation_detail/widgets.dart` - UI CommunicationFeedbackCard

### UI en Detalle de Conversación
El widget `CommunicationFeedbackCard` muestra:
1. **Resumen** - Estilo de comunicación en una oración
2. **Fortalezas** - Lista con checkmarks verdes
3. **Áreas de Mejora** - Lista con lightbulbs amarillos
4. **Observaciones** - Claridad, estructura, llamados a acción, objeciones
5. **Métricas** - Chips con contadores:
   - Contador de "pero" (naranja)
   - Total de muletillas (morado)
   - Total de objeciones (rojo)
6. **Detalles de muletillas** - Frecuencia por palabra
7. **Objeciones recibidas/hechas** - Listas separadas

### Configuración OpenAI
- Modelo: `gpt-4o-mini`
- max_tokens: 800
- temperature: 0.7

## Patrón para BuildContext con Operaciones Async

Para evitar el warning `use_build_context_synchronously`, siempre capturar referencias a widgets/servicios basados en context **ANTES** de operaciones async:

### Patrón Correcto
```dart
Future<void> myAsyncMethod() async {
  if (!mounted) return;  // Check ANTES

  // Capturar ANTES del await
  final provider = context.read<MyProvider>();
  final navigator = Navigator.of(context);
  final scaffoldMessenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);

  await someAsyncOperation();  // Operación async

  if (!mounted) return;  // Check DESPUÉS

  // Usar referencias capturadas (NO context directo)
  navigator.push(...);
  scaffoldMessenger.showSnackBar(...);
}
```

### Archivos con Patrón Aplicado
- `lib/pages/home/page.dart` - Connectivity banners, navigation
- `lib/core/app_shell.dart` - initState providers
- `lib/pages/conversation_detail/page.dart` - Share, action items
- `lib/pages/onboarding/wrapper.dart` - Device connection flow

### Reglas
1. Siempre verificar `mounted` antes y después de awaits en StatefulWidget
2. Capturar Navigator, ScaffoldMessenger, Providers ANTES del await
3. No usar `context.read<>()` después de un await sin verificar mounted
4. Para callbacks en widgets stateless, usar el context del builder

## Documentación Adicional

- `docs/CHAT_AGENT_DIFFERENCES.md` - Comparación detallada del chat agent entre Accounting y OMI (tools, prompts, providers)
- `docs/google-sign-in-setup.md` - Configuración de Google Sign-In para Supabase Auth
