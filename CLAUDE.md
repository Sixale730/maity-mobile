# Maity - Asistente de IA con Wearable

App Flutter + wearable OMI via BLE. Transcribe conversaciones en tiempo real y genera analisis con IA.

**Soporte**: julio.gonzalez@maity.com.mx

## Arquitectura
```
Flutter App → Vercel Backend (FastAPI) → Supabase (PostgreSQL + pgvector)
                    ↓
               OpenAI (analisis + embeddings)
```

**Stack**: Flutter (iOS/Android/Desktop) · Vercel Serverless (Python/FastAPI) · Supabase PostgreSQL + pgvector · OpenAI (GPT-4o-mini, text-embedding-3-small) · Deepgram STT · Mixpanel/Firebase Analytics

## Supabase
- URL: `https://nhlrtflkxoojvhbyocet.supabase.co`
- Schema: `maity` (shared with web platform)
- pgvector v0.8.0 (1536 dims for text-embedding-3-small)
- RLS: Todas las tablas usan `auth.uid() = auth_id`

## Database Schema

**maity.users**: `id` (UUID PK), `auth_id` (FK auth.users), `email`, `name`. Trigger `handle_new_auth_user()` crea registro en signup.

**maity.omi_conversations**: `id`, `user_id` (FK), `title`, `overview`, `emoji`, `category`, `action_items`/`events` (JSONB), `transcript_text`, `embedding` (vector(1536)), `words_count`, `duration_seconds`, `discarded` (bool default false), `last_segment_at`, `segment_count`, `status`. Indices HNSW.

**maity.omi_transcript_segments**: `id`, `conversation_id` (FK), `user_id`, `text`, `speaker`, `speaker_id`, `is_user`, `start_time`, `end_time`, `embedding` (vector(1536)). Unique index: `(conversation_id, segment_index)`.

**maity.voice_profiles**: `id`, `user_id` (UNIQUE), `auth_id`, `embedding` (vector(192) ECAPA-TDNN), `enrollment_duration_seconds`, `samples_count`, `is_active`.

**maity.omi_memories**: `id`, `user_id`, `auth_id`, `conversation_id` (nullable FK), `content`, `category` ('interesting'|'system'|'manual'), `reviewed`, `user_review`, `manually_added`, `edited`, `deleted`, `visibility`, `is_locked`, `embedding` (vector(1536)).

**maity.user_feedback**: `id`, `user_id`, `auth_id`, `feedback_type` ('comment'|'bug'|'suggestion'), `message`, `app_version`, `device_info`, `status`, `created_at`.

**maity.daily_communication_reports**: `id`, `user_id` (FK), `auth_id`, `report_date` (UNIQUE con user_id), contadores (`total_filler_words/count`, `total_pero_count`, `total_objection_words`), scores NUMERIC(3,1) (`score_clarity/structure/calls_to_action/objection_handling/overall`), `top_strengths/areas_to_improve/recommendations` (JSONB), `daily_summary`, `trend` (improving|stable|declining|first_report), `trend_details`, `conversation_ids`.

**RPC Functions**: `search_omi_conversations`, `search_omi_segments`, `get_omi_conversation_with_segments`, `get_voice_profile`, `search_omi_memories`, `get_pending_memories`.

## Archivos Clave

### Providers (`lib/providers/`)
- `auth_provider.dart` - Auth Supabase
- `conversation_provider.dart` - Estado conversaciones + busqueda semantica
- `capture_provider.dart` - Grabacion, transcripcion, guardado, health monitor, recovery
- `usage_provider.dart` - Estadisticas
- `memories_provider.dart` - CRUD memorias + revision
- `action_items_provider.dart` - Tareas
- `daily_report_provider.dart` - Reportes diarios comunicacion
- `dashboard_provider.dart` - Agrega datos para Dashboard (score, stats, tareas)

### Services (`lib/services/`)
- `supabase_auth_service.dart` - Auth (Google Sign-In)
- `maity_api_service.dart` - API backend Vercel
- `omi_supabase_service.dart` - Operaciones Supabase (createDraft, appendSegments, finalize)
- `voice_profile_service.dart` - Enrollment y verificacion voz
- `feedback_service.dart` - Feedback usuarios
- `conversation_processor.dart` - Procesamiento local con OpenAI
- `transcript_recovery_service.dart` - Recovery de conversaciones interrumpidas
- `incremental_save_service.dart` - Guardado incremental a Supabase
- `daily_report_service.dart` - HTTP para reportes diarios

### Otros
- `lib/backend/http/shared.dart` - Cliente HTTP con auth centralizada
- `lib/backend/schema/` - Modelos de datos
- `lib/pages/home/page.dart` - Pagina principal

## Navegacion

### Bottom Nav (5 posiciones, FAB central)
| Nav Index | Tab | Icono | Stack Index | Pagina |
|-----------|-----|-------|-------------|--------|
| 0 | Home | `house` | 0 | DashboardPage (score diario, stats, acciones rapidas) |
| 1 | Conversations | `message` | 1 | ConversationsPage |
| 2 | (FAB) | `mic` | - | Boton grabar (interceptado, no cambia stack) |
| 3 | Tasks | `listCheck` | 2 | ActionItemsPage |
| 4 | Insights | `chartLine` | 3 | UsagePage |

### Navigation Drawer (hamburger icon en AppBar)
- **Principal**: Home, Conversaciones, Tareas
- **Analisis**: Insights, Memorias (Navigator.push), Reporte Diario
- **Perfil**: Configuracion (SettingsDrawer), Perfil de Voz

**Memorias**: Solo accesible via drawer con `Navigator.push`, no esta en IndexedStack.

### Archivos navegacion
- `lib/pages/home/page.dart` - Pagina principal con bottom nav + drawer
- `lib/pages/home/widgets/app_navigation_drawer.dart` - Drawer lateral
- `lib/pages/dashboard/dashboard_page.dart` - Dashboard con score, stats, acciones rapidas
- `lib/pages/dashboard/widgets/` - Widgets del dashboard (header, score card, stats, etc.)
- `lib/providers/home_provider.dart` - Estado nav, `stackIndex` getter, `setIndex()` (intercepta FAB index 2)

## Conversaciones

### Filtros (SearchWidget)
- Busqueda semantica/texto toggle
- Filtro por fecha
- Filtro conversaciones cortas (umbral configurable: 0/30/60/120/300s, default 60s)

**Settings**: `showShortConversations` (bool), `shortConversationThreshold` (int segundos) en `preferences.dart`.

**Archivos filtro cortas**: `short_conversation_dialog.dart`, `search_widget.dart`, `conversation_provider.dart`, `preferences.dart`.

### Banal Conversation Filter (Discarded)
Dos niveles: pre-filtro metricas (sin IA) + analisis IA.

**Pre-filtro**: <5 palabras, <10s Y <10 palabras, 1 segmento <3 palabras → `discarded: true`.

**IA**: OpenAI evalua si banal → `discarded: true` para saludos casuales, ruido, fragmentos sin contexto.

**Backend**: `should_auto_discard()` en `api/routers/omi.py`. **Flutter**: campo `discarded` en `Structured` model y `conversation_processor.dart`. UI soporta `include_discarded`.

### Detalle de Conversacion
`lib/pages/conversation_detail/page.dart` - Tabs: Transcription, Summary, Action Items.

## Action Items
Extraidos por OpenAI de conversaciones, guardados en `omi_conversations.action_items` (JSONB).

**Tabs**: To Do (ultimos 3 dias), Done, Old (>3 dias). **ID format**: `{conversation_id}_{index}`.

**Endpoints**: GET `/v1/action-items/from-conversations`, PATCH/DELETE `/v1/action-items/{id}`.

**Archivos**: `api/routers/action_items.py`, `lib/backend/http/api/action_items.dart`, `lib/providers/action_items_provider.dart`, `lib/pages/action_items/action_items_page.dart`, `lib/backend/schema/action_item.dart`.

## Insights (UsagePage)
`lib/pages/settings/usage_page.dart`

5 metricas: Listening (min), Understanding (words), Providing (insights), Conversations (count), Memories (count).

**Endpoint**: GET `/v1/users/{id}/metrics` → stats + history diario.

**Archivos backend**: `api/routers/metrics.py`, `api/services/supabase_client.py`, `api/models/metrics.py`. **Flutter**: `lib/providers/usage_provider.dart`, `lib/models/user_usage.dart`.

## Data Persistence (Grabacion)

### Incremental Save (3 fases)
1. **Draft**: primer segmento → `POST /v1/omi/conversations/draft` → row `status='recording'`
2. **Segments**: cada 30s o 20 segmentos → `POST /v1/omi/conversations/{id}/segments` (upsert idempotente, ON CONFLICT DO NOTHING)
3. **Finalize**: al detener → `POST /v1/omi/conversations/{id}/finalize` → rebuild transcript, embeddings, memorias, status='completed'

**Reprocess**: `POST /v1/omi/conversations/{id}/reprocess` para re-analizar existentes.

**Procesamiento**: ≤6,000 chars local (Flutter+OpenAI), >6,000 chars backend chunked (~5,000 chars/chunk, max 3 concurrentes).

**Health monitor**: timer cada 10s, alerta si >60s sin segmentos. Notificacion ID: 3.

**Fallback**: si incremental falla, `store_conversation` monolitico funciona. `get_conversations` filtra `status='completed'`.

**Archivos backend**: `api/routers/omi.py`, `api/services/supabase_client.py`, `api/services/chunked_processor.py`, `api/services/utils.py`. **Flutter**: `lib/services/incremental_save_service.dart`, `lib/services/omi_supabase_service.dart`, `lib/providers/capture_provider.dart`.

### Transcript Recovery (crash/kill)
Segmentos se guardan a archivo JSON cada 5s (debounce) o 5 nuevos segmentos. Al reiniciar, `RecoveryDialog` ofrece recuperar o descartar. Expiracion: 24h. Minimo recuperable: 5 palabras. 3 reintentos con backoff.

**Archivos**: `lib/services/transcript_recovery_service.dart`, `lib/models/recovery_session.dart`, `lib/widgets/recovery_dialog.dart`.

### Segmentos de Transcripcion
- IDs formato: `{timestamp}_{start}_{index}`
- `mergeConsecutiveSegmentsByTime()`: mismo speaker, gap <3s
- Auto-guardado por silencio: default 120s → `_onSilenceTimeout()`

**Proteccion doble guardado**: Flag `_conversationFinalized` en CaptureProvider.

## Autenticacion (Supabase Auth)

**Flujo**: Google Sign-In → idToken → `SupabaseAuthService.signInWithGoogleNative()` → Supabase → trigger crea `maity.users` → `fetchMaityUserId()`.

**Tokens**: `getAccessToken()` auto-refresh 5 min antes de expirar. Retry en 401.

**IDs**: `auth.users.id` (UUID Auth, `sub` en JWT) vs `maity.users.id` (UUID tabla, usado en queries).

**Dominio auth**: `maity-mobile.vercel.app` en `_isRequiredAuthCheck()`.

**Auto-onboarding**: Si `maityUserId != null` al login → `onboardingCompleted = true`.

## Vercel Backend Endpoints

| Endpoint | Metodo | Descripcion |
|----------|--------|-------------|
| `/v1/omi/conversations/store` | POST | Guardar con embeddings |
| `/v1/omi/conversations/search` | POST | Busqueda semantica |
| `/v1/omi/conversations` | GET | Listar (status='completed') |
| `/v1/omi/conversations/{id}` | GET | Obtener con segmentos |
| `/v1/omi/conversations/draft` | POST | Crear draft |
| `/v1/omi/conversations/{id}/segments` | POST | Upsert segmentos |
| `/v1/omi/conversations/{id}/finalize` | POST | Finalizar conversacion |
| `/v1/omi/conversations/{id}/reprocess` | POST | Re-analizar |
| `/v1/users/{id}/metrics` | GET | Metricas por periodo |
| `/v1/users/{id}/metrics/summary` | GET | Resumen metricas |
| `/v2/messages` | POST | Chat con function calling |
| `/v1/feedback/*` | * | Submit, list, my |
| `/v1/memories/*` | * | CRUD, extract, search, review |
| `/v1/voice/*` | * | Enroll, verify-speakers, status, delete |
| `/v1/action-items/*` | GET/PATCH/DELETE | CRUD action items |
| `/v1/daily-reports/*` | GET/POST | Generate (cron), latest, by-date, history |
| `/v1/communication/analyze` | POST | Analisis comunicacion |

## API Legacy (api.omi.me)

Funciones en `lib/backend/http/api/` deshabilitadas (retornan default) o redirigidas a `OmiSupabaseService`: `getConversationById` → `OmiSupabaseService.getConversation()`, `getConversations` → `OmiSupabaseService.getConversations()`.

Deshabilitadas en `users.dart`: `setConversationSummaryRating`, `getHasConversationSummaryRating`, `updateUserGeolocation`, `getPrivateCloudSyncEnabled`, `getAllPeople`, `getUserUsage`, `getTrainingDataOptIn`, `getUserSubscription`.

## Chat Agent

Flutter → `/v2/messages` → OpenAI gpt-4o-mini + function calling → Supabase.

**8 tools**: `buscar_conversaciones`, `obtener_conversacion`, `buscar_semantico`, `resumen_dia`, `obtener_action_items`, `buscar_por_categoria`, `estadisticas_uso`, `feedback_comunicacion`.

**Quick Actions**: Resumen de hoy, Mis pendientes, Mis estadisticas, Como me comunico.

**Archivos**: `api/routers/messages.py`, `lib/pages/chat/page.dart`.

## Speaker Verification

**Enrollment**: Flutter → `/v1/voice/enroll` → Modal.com (ECAPA-TDNN, speechbrain/spkrec-ecapa-voxceleb) → embedding vector(192) → Supabase. Validacion: 10-155s, min 25 palabras. Soporta BLE y phone mic.

**Verificacion automatica**: Al finalizar conversacion, compara audio por speaker con perfil. Threshold: 0.75-0.80. Re-etiqueta `is_user`.

**Phone mic enrollment**: `SpeechProfileProvider.initialise(usePhoneMic: true)` → PCM16, 100fps, 320 bytes/frame. Sin BLE: boton principal usa phone mic. Con BLE: link secundario.

**Error codes**: `AUTH_REQUIRED`, `ENROLLMENT_FAILED`, `ENROLLMENT_VERIFICATION_FAILED`, `TOO_SHORT`, `NO_SPEECH`, `MULTIPLE_SPEAKERS`.

**Deploy**: `cd modal_functions && python -m modal deploy voice_embeddings.py`. Env: `MODAL_VOICE_ENDPOINT_URL`.

**Archivos**: `modal_functions/voice_embeddings.py`, `api/routers/voice_profiles.py`, `lib/services/voice_profile_service.dart`, `lib/providers/speech_profile_provider.dart`, `lib/pages/speech_profile/page.dart`.

## Feedback de Comunicacion

Conversacion → `/v1/communication/analyze` → OpenAI (timeout 20s) → CommunicationFeedback.

**Modelo**: strengths, areas_to_improve (max 5 c/u), observations (claridad, estructura, llamados a accion, objeciones), counters (pero_count, filler_words, objections).

**Muletillas**: "este", "o sea", "como que", "bueno", "entonces", "basicamente", "literalmente", "tipo", "digamos", "la verdad".

**Archivos**: `api/models/communication.py`, `api/services/communication_analyzer.py`, `lib/pages/conversation_detail/widgets.dart`.

## Evaluacion Diaria de Comunicacion

Cron job (`0 0 * * *` UTC, 6 PM Mexico CST) genera reportes diarios via OpenAI analizando communication_feedback del dia. Idempotente (UNIQUE constraint + upsert).

**Tendencia**: `|change| < 0.5` → stable, `> 0` → improving, `< 0` → declining, primer reporte → `first_report`.

**Flutter UI**: DailyReportCard en Insights tab + MaterialBanner in-app (dismiss en `lastDismissedDailyReport`).

**Endpoints**: POST `/v1/daily-reports/generate` (CRON_SECRET), GET `latest`, `by-date`, `history`.

**Archivos backend**: `api/models/daily_report.py`, `api/services/daily_report_generator.py`, `api/routers/daily_reports.py`. **Flutter**: `lib/models/daily_communication_report.dart`, `lib/services/daily_report_service.dart`, `lib/providers/daily_report_provider.dart`, `lib/pages/settings/widgets/daily_report_card.dart`.

## Sistema de Memorias

Extraccion automatica en `store_conversation()`: si no discarded y transcript >=50 chars → OpenAI extrae 2-5 memorias (timeout 20s, max 4000 chars) → embeddings → `omi_memories` con `reviewed=false`.

**Categorias**: `interesting` (IA), `system`, `manual`. **Revision**: swipe en MemoriesPage.

**Archivos**: `api/routers/memories.py`, `api/services/memory_extractor.py`, `api/models/memory.py`, `lib/providers/memories_provider.dart`, `lib/pages/memories/`.

## Notificaciones

`NotificationService` singleton (`awesome_notifications`). Auto-solicita permisos.

| ID | Uso | Origen |
|----|-----|--------|
| 1 | Dispositivo desconectado (5s delay) | `device_provider.dart` |
| 2 | Dispositivo conectado | `device_provider.dart` |
| 3 | Transcripcion detenida (>60s) | `capture_provider.dart` |

**Foreground service**: Estados: waiting, device_connected, phone_mic, recording, processing, ready. Botones en waiting: Connect, Use Mic.

## Bluetooth (BLE)

**Archivos**: `lib/services/devices/transports/ble_transport.dart`, `lib/services/devices/discovery/bluetooth_discoverer.dart`, `lib/providers/device_provider.dart`.

**Comportamientos clave**:
- `allowLongWrite: true` automatico cuando data > MTU-3
- Timeout 10s esperando adaptador BT
- Android: 2s delay post-activacion BT (permisos)
- Reconexion exponential backoff: 2s inicial, 1.5x, max 60s, 8 reintentos
- Desconexion: 5s delay antes de notificar (permite reconexion rapida)

## Settings Drawer

**Perfiles**: Developer (`*@asertio.mx`) tiene Storage, Developer Settings, Feedback Received. Usuario final: opciones reducidas.

## Internacionalizacion (i18n)

- **Archivos**: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- **Uso**: `AppLocalizations.of(context)!.keyName`
- **Generar**: `flutter gen-l10n`
- **Runtime**: `MyApp.changeLocale('es')`
- **Fechas**: `dateTimeFormat('MMM dd', date, locale: SharedPreferencesUtil().appLanguage)`

## Analytics (Mixpanel)

Token en `.env` → `MIXPANEL_PROJECT_TOKEN`. Singleton `MixpanelManager` en `lib/utils/analytics/mixpanel.dart`. Mobile: `mixpanel_flutter`, Desktop: `mixpanel_analytics` (HTTP). Init en `main.dart`. Test button en Developer Settings.

## VAD (Voice Activity Detection)

Requiere: VAD habilitado + Custom STT (Deepgram) + PCM16. Estados: Silence → Pre-Roll → Speech → Hang-Over. Metricas en Developer Settings.

**Archivos**: `lib/services/vad/vad_metrics.dart`, `lib/services/vad/vad_state.dart`, `lib/providers/capture_provider.dart` (`vadStateNotifier`, `vadMetrics`).

## Backend

Codigo en `C:\OMI\api\`: `index.py` (FastAPI), `routers/` (omi, metrics, feedback, memories, voice_profiles, messages, action_items, daily_reports), `services/` (supabase_client, embeddings, memory_extractor, communication_analyzer, chunked_processor, utils), `models/`.

### Variables de Entorno
**Vercel**: `OPENAI_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SUPABASE_JWT_SECRET`, `MODAL_VOICE_ENDPOINT_URL`, `CRON_SECRET`.

**Flutter .env**: `MIXPANEL_PROJECT_TOKEN`, `DEEPGRAM_API_KEY`, `GOOGLE_CLIENT_ID`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`.

## Assets

Logos en `assets/images/` (rosa #F93A6E). Regenerar: `dart run flutter_launcher_icons` / `dart run flutter_native_splash:create`.

## Patrones

**BuildContext async**: Verificar `mounted` antes/despues de awaits, capturar Navigator/ScaffoldMessenger antes del await.

**API disabled pattern**: `debugPrint('[API Disabled]')` + return default. **Redirect pattern**: delegate a `OmiSupabaseService`.

## Docs

`docs/CHAT_AGENT_DIFFERENCES.md`, `docs/google-sign-in-setup.md`, `docs/MIXPANEL_GUIDE.md`.
