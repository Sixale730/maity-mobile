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
- lib/services/maity_api_service.dart - API backend (procesa y almacena en Supabase)
- lib/services/omi_supabase_service.dart - Servicio para operaciones Supabase
- lib/services/voice_profile_service.dart - Servicio para enrollment y verificación de voz
- lib/backend/http/shared.dart - Cliente HTTP con autenticacion centralizada
- lib/backend/schema/conversation.dart - Modelos de datos

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
7. Dashboard de metricas
8. UI para mostrar resultados de busqueda semantica
9. Limpiar código legacy de Firebase Auth

## Vercel Backend Endpoints (OMI)
| Endpoint | Metodo | Descripcion |
|----------|--------|-------------|
| `/v1/omi/conversations/store` | POST | Guarda conversacion con embeddings |
| `/v1/omi/conversations/search` | POST | Busqueda semantica |
| `/v1/omi/conversations` | GET | Listar conversaciones |
| `/v1/omi/conversations/{id}` | GET | Obtener conversacion con segmentos |

## Backend (Monorepo)
Codigo en `C:\OMI\api\` (misma carpeta que Flutter app):
- `api/index.py` - FastAPI entry point
- `api/routers/omi.py` - Endpoints OMI para Supabase
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

VERIFICACIÓN (pendiente buffer de audio):
Conversación finaliza → Extraer audio por speaker → Modal → Comparar con perfil → Re-etiquetar is_user
```

### Flujo de Enrollment
1. Usuario va a Speech Profile y graba 30+ segundos
2. `SpeechProfileProvider.finalize()` crea archivo WAV
3. Llama `VoiceProfileService.enrollVoiceProfile(userId, audioFile)`
4. Backend Vercel envía audio a Modal.com
5. Modal extrae embedding ECAPA-TDNN (192 dims)
6. Se guarda en `maity.voice_profiles`

### Modal.com (Servicio ML)
Archivo: `modal_functions/voice_embeddings.py`
- Modelo: speechbrain/spkrec-ecapa-voxceleb (ECAPA-TDNN)
- GPU: T4 (económica)
- Endpoints HTTP:
  - `/extract_embedding_http` - Extrae embedding de audio
  - `/verify_speakers_http` - Verifica múltiples speakers
  - `/health` - Health check

Deploy: `modal deploy voice_embeddings.py`

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
- `lib/providers/capture_provider.dart` - Preparado para verificación

### Estado Actual
- [x] Enrollment de perfil de voz (funcional)
- [x] Backend Vercel con endpoints
- [x] Modal.com con ECAPA-TDNN
- [x] Tabla voice_profiles en Supabase
- [ ] Buffer de audio en CaptureProvider
- [ ] Verificación batch al finalizar conversación

### Pendiente para Verificación Completa
Para re-etiquetar `is_user` basado en huella de voz:
1. Agregar `WavBytesUtil _audioBuffer` a CaptureProvider
2. Almacenar audio en `streamAudioToWs()` callback
3. En `_verifySpeakersWithVoiceProfile()`:
   - Extraer audio por timestamps de segmento
   - Llamar `VoiceProfileService.verifySpeakers()`
   - Re-etiquetar segmentos

### Umbral de Similitud
- 0.65-0.70: Muy permisivo (más falsos positivos)
- 0.75-0.80: Balanceado (recomendado)
- 0.85-0.90: Estricto (más falsos negativos)
