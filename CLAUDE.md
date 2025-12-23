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
- Tables: `maity.omi_conversations`, `maity.omi_transcript_segments`

## Database Schema

### maity.omi_conversations
Tabla principal para conversaciones del wearable con embedding vectorial:
- `id` (UUID) - Primary key
- `firebase_uid` (TEXT) - Usuario Firebase (temporal, se migrara a Supabase Auth)
- `user_id` (UUID) - Referencia a maity.users (para futura migracion)
- `title`, `overview`, `emoji`, `category` - Datos estructurados del AI
- `action_items`, `events` (JSONB) - Items de accion y eventos
- `transcript_text` (TEXT) - Transcripcion completa
- `embedding` (vector(1536)) - Embedding para busqueda semantica
- `words_count`, `duration_seconds` - Metricas
- Indices HNSW para busqueda vectorial rapida

### maity.omi_transcript_segments
Segmentos individuales de transcripcion con embeddings granulares:
- `id` (UUID), `conversation_id` (UUID FK)
- `text`, `speaker`, `speaker_id`, `is_user`
- `start_time`, `end_time` - Timing del segmento
- `embedding` (vector(1536)) - Para busqueda granular

### RPC Functions
- `maity.search_omi_conversations()` - Busqueda semantica de conversaciones
- `maity.search_omi_segments()` - Busqueda semantica de segmentos
- `maity.get_omi_conversation_with_segments()` - Obtener conversacion con segmentos

## Archivos Clave
- lib/providers/auth_provider.dart - Autenticacion Firebase (pendiente migrar a Supabase)
- lib/providers/conversation_provider.dart - Estado de conversaciones + busqueda semantica
- lib/services/maity_api_service.dart - API backend (procesa y almacena en Supabase)
- lib/services/omi_supabase_service.dart - Servicio para operaciones Supabase
- lib/backend/http/shared.dart - Cliente HTTP con autenticacion centralizada
- lib/backend/schema/conversation.dart - Modelos de datos

## Autenticacion

### Flujo de Token
1. Usuario inicia sesion con Firebase Auth
2. `AuthService.getIdToken()` obtiene/renueva el token JWT
3. Token se almacena en `SharedPreferencesUtil().authToken`
4. `getAuthHeader()` en `shared.dart` devuelve `Bearer <token>`

### Dominios Autenticados
La funcion `_isRequiredAuthCheck()` en `shared.dart` determina que URLs requieren el header Authorization:
- URLs que contienen `Env.apiBaseUrl` (API principal OMI)
- `maity-backend.vercel.app` (Backend Maity/Supabase)

### Retry de Token
`makeApiCall()` implementa retry automatico en caso de 401:
1. Detecta respuesta 401
2. Llama `AuthService.getIdToken()` para renovar token
3. Reintenta la peticion con nuevo token
4. Si falla de nuevo, fuerza sign-out del usuario

## Flujo de Datos

### Guardar Conversacion
1. MaityApiService.processConversation() procesa con OpenAI
2. Automaticamente llama OmiSupabaseService.storeConversation()
3. Vercel backend genera embeddings y guarda en Supabase

### Busqueda Semantica
1. ConversationProvider.semanticSearchConversations(query, firebaseUid)
2. OmiSupabaseService.searchConversations() llama a Vercel
3. Vercel genera embedding del query y busca por similitud coseno
4. Fallback automatico a busqueda de texto si falla

## Pendiente
1. ~~Crear proyecto Supabase con pgvector~~ DONE
2. ~~Crear backend en Vercel~~ DONE (endpoints OMI)
3. Integrar supabase_flutter (para auth futuro)
4. Migrar auth de Firebase a Supabase
5. ~~Implementar guardado de conversaciones~~ DONE
6. ~~Agregar busqueda semantica~~ DONE
7. Dashboard de metricas
8. UI para mostrar resultados de busqueda semantica

## Vercel Backend Endpoints (OMI)
| Endpoint | Metodo | Descripcion |
|----------|--------|-------------|
| `/v1/omi/conversations/store` | POST | Guarda conversacion con embeddings |
| `/v1/omi/conversations/search` | POST | Busqueda semantica |
| `/v1/omi/conversations` | GET | Listar conversaciones |
| `/v1/omi/conversations/{id}` | GET | Obtener conversacion con segmentos |
