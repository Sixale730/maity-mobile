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
- Tables: `maity.omi_conversations`, `maity.omi_transcript_segments`, `maity.voice_profiles`, `maity.user_feedback`

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

### maity.user_feedback
Feedback de usuarios (comentarios, bugs, sugerencias):
- `id` (UUID) - Primary key
- `user_id` (UUID) - Referencia a maity.users.id
- `auth_id` (UUID) - FK a auth.users.id
- `feedback_type` (TEXT) - Tipo: 'comment', 'bug', 'suggestion'
- `message` (TEXT) - Contenido del feedback
- `app_version` (TEXT) - Versión de la app
- `device_info` (TEXT) - Info del dispositivo
- `status` (TEXT) - Estado: 'pending', 'reviewed', 'resolved'
- `created_at` (TIMESTAMP) - Fecha de creación
- RLS: Usuarios solo pueden insertar y ver su propio feedback

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
- lib/services/feedback_service.dart - Servicio para envío y consulta de feedback
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

## Página de Detalle de Conversación

La página `lib/pages/conversation_detail/page.dart` muestra el detalle de una conversación con tres tabs:

### Tabs (ConversationTab)
| Tab | Título (EN) | Título (ES) | Descripción |
|-----|-------------|-------------|-------------|
| transcript | Transcription | Transcripción | Transcripción completa con timestamps |
| summary | Summary | Resumen | Resumen generado por IA |
| actionItems | Action Items | Elementos de Acción | Lista de acciones a tomar |

### AppBar Actions
La barra de navegación superior tiene los siguientes botones:
1. **Botón de Búsqueda** (🔍) - Solo visible en tabs de Transcripción y Resumen
2. **Menú de 3 puntos** (⋮) - Opción única: "Eliminar" (localizado)

**Funcionalidad removida**:
- Botón de compartir (share) - Eliminado para simplificar la UI
- Opciones del menú: Copy Transcript, Copy Summary, Test Prompt, Reprocess Conversation
- Botón "Generate Summary" con borde morado gradiente - Eliminado de GetAppsWidgets (solo muestra "No summary available" cuando no hay resumen)
- Dropdown de "Summary Template" en barra inferior - Eliminado de ConversationBottomBar (el tab de Summary ahora solo cambia de tab, no abre modal)

### Localización
Los títulos de los tabs usan `AppLocalizations`:
- `l10n.transcription` → "Transcription" / "Transcripción"
- `l10n.summary` → "Summary" / "Resumen"
- `l10n.actionItems` → "Action Items" / "Elementos de Acción"

## Assets y Splash Screen

### Imágenes de Logo
- `assets/images/app_launcher_icon.png` - Logo blanco sobre transparente (base para launcher icon)
- `assets/images/maity_launcher_icon.png` - Logo rosa (#F93A6E) sobre transparente, usado para launcher icon Android
- `assets/images/maity_icon.png` - Logo original con colores (1340×1345 px)
- `assets/images/maity_splash.png` - Logo para splash screen (1152×1152 px, logo ~600px centrado)

### App Launcher Icon (Android)
El icono de la app usa el sistema de adaptive icons de Android:
- **Foreground**: `maity_launcher_icon.png` (logo rosa #F93A6E con padding adecuado)
- **Background**: `#0F0F0F` (negro)
- Configurado en `pubspec.yaml` sección `flutter_launcher_icons`
- Regenerar con: `dart run flutter_launcher_icons`

**Nota**: `maity_launcher_icon.png` se genera a partir de `app_launcher_icon.png` cambiando el color blanco a rosa (#F93A6E).
Para regenerar, usar PIL: reemplazar píxeles donde R>200, G>200, B>200 por (249, 58, 110).

Archivos generados en `android/app/src/main/res/mipmap-*/`:
- `ic_launcher.png` - Icono estándar
- `ic_launcher_foreground.png` - Capa frontal (logo)
- `ic_launcher_background.png` - Capa de fondo (color)

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

### Perfiles de Usuario
La app distingue entre dos perfiles basados en el dominio del email:

| Perfil | Email | Acceso |
|--------|-------|--------|
| **Developer** | `*@asertio.mx` | Todas las opciones (Storage, Developer Settings) |
| **Usuario Final** | Cualquier otro email | Opciones reducidas (sin Storage ni Developer Settings) |

**Helper**: `_isDeveloperUser()` en `settings_drawer.dart` verifica si el email termina en `@asertio.mx`

### Secciones

**Perfil y Dispositivo:**
- Profile - Configuración de perfil
- Storage - Sincronización de datos (**solo Developer**)
- Device Settings - Configuración Bluetooth

**Compartir:**
- Share Maity → maity.com.mx

**Feedback:**
- Send Feedback → FeedbackPage (formulario para enviar comentarios/bugs/sugerencias)
- Feedback Received → FeedbackListPage (**solo Developer** - ver todos los feedback)

**Privacidad y Configuración:**
- Data & Privacy
- Language - Selector de idioma (es/en)
- Developer Settings (**solo Developer**)
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
- FindDevicesPage - Pantalla de conexión de dispositivo
- ConnectDevicePage - Pantalla de reconexión de dispositivo
- DataPrivacyPage - Página de datos y privacidad
- PrivacyInfoPage - Página de información de privacidad (About → Privacy Policy)
- AboutOmiPage - Página About Maity
- SyncPage (Storage) - Página de almacenamiento (solo developers)
- PrivateCloudSyncPage - Sincronización en nube privada
- AboutSdCardSync - Información de sincronización de SD Card

### Página de Datos y Privacidad
La página Data & Privacy está completamente localizada incluyendo la sección de protección de datos:

| Clave | Inglés | Español |
|-------|--------|---------|
| `maximumSecurityE2ee` | Maximum Security (E2EE) | Máxima Seguridad (E2EE) |
| `e2eeDialogContent` | End-to-end encryption is the gold standard... | La encriptación de extremo a extremo es el estándar de oro... |
| `importantTradeoffs` | Important Trade-offs: | Consideraciones importantes: |
| `e2eeTradeoff1` | Some features like external app integrations... | Algunas funciones como integraciones con apps externas... |
| `e2eeTradeoff2` | If you lose your password... | Si pierdes tu contraseña... |
| `featureComingSoon` | This feature is coming soon! | ¡Esta función estará disponible pronto! |
| `comingSoon` | Coming Soon | Próximamente |
| `migrationInProgress` | Migration in progress... | Migración en progreso... |
| `migrationFailed` | Migration Failed | Migración Fallida |
| `migratingFrom` | Migrating from | Migrando de |
| `migratingTo` | to | a |
| `objects` | objects | objetos |
| `secureEncryption` | Secure Encryption | Encriptación Segura |
| `secureEncryptionDesc` | Your data is encrypted with a key unique to you... | Tus datos están encriptados con una clave única para ti... |
| `endToEndEncryption` | End-to-End Encryption | Encriptación de Extremo a Extremo |
| `e2eeShortDesc` | Enable for maximum security... | Activa para máxima seguridad... |
| `dataAlwaysEncrypted` | Regardless of the level, your data is always encrypted... | Independientemente del nivel, tus datos siempre están encriptados... |

**Archivos**:
- `lib/pages/settings/data_privacy_page.dart` - Página principal
- `lib/pages/settings/widgets/data_protection_section.dart` - Sección de protección de datos

### Página de Información de Privacidad (Privacy Policy)
La página de Política de Privacidad (accesible desde About Maity) está completamente localizada:

| Clave | Inglés | Español |
|-------|--------|---------|
| `privacyInformationTitle` | Privacy Information | Información de Privacidad |
| `yourPrivacyMatters` | Your Privacy Matters to Us | Tu Privacidad Nos Importa |
| `privacyIntro` | At Maity, we take your privacy very seriously... | En Maity, nos tomamos tu privacidad muy en serio... |
| `whatWeTrack` | What We Track | Lo Que Rastreamos |
| `anonymityAndPrivacy` | Anonymity and Privacy | Anonimato y Privacidad |
| `optInOutOptions` | Opt-In and Opt-Out Options | Opciones de Participación |
| `ourCommitment` | Our Commitment | Nuestro Compromiso |
| `privacyCommitmentText` | We are committed to using the data... | Estamos comprometidos a usar los datos... |
| `privacyThankYou` | Thank you for being a valued user of Maity... | Gracias por ser un usuario valioso de Maity... |

**Email de soporte**: `julio.gonzalez@maity.com.mx`

**Archivos**:
- `lib/pages/settings/privacy.dart` - Página de información de privacidad
- `lib/pages/settings/about.dart` - Página About Maity (navega a PrivacyInfoPage)

**Nota**: La página de privacidad ahora es local (no WebView) y muestra contenido de Maity (no Omi).

### Página de Almacenamiento (Storage)
La sección de Storage (solo visible para developers `@asertio.mx`) está completamente localizada:

**Archivos**:
- `lib/pages/conversations/sync_page.dart` - Página principal de almacenamiento
- `lib/pages/conversations/private_cloud_sync_page.dart` - Sincronización en nube privada
- `lib/pages/sdcard/about_sdcard_sync.dart` - Información sobre sincronización de SD Card

| Clave | Inglés | Español |
|-------|--------|---------|
| `storageSettings` | Storage Settings | Configuración de Almacenamiento |
| `completeArchive` | Complete Archive | Archivo Completo |
| `completeArchiveDesc` | Create a complete personal archive... | Crea un archivo personal completo... |
| `privateCloudSync` | Private Cloud Sync | Sincronización en Nube Privada |
| `privateCloudSyncDesc` | Store real-time recordings in the private cloud | Almacena grabaciones en tiempo real en la nube privada |
| `allRecordings` | All Recordings | Todas las Grabaciones |
| `phoneStorage` | Phone Storage | Almacenamiento del Teléfono |
| `sdCard` | SD Card | Tarjeta SD |
| `privacyAndConsent` | Privacy & Consent | Privacidad y Consentimiento |
| `creatingConversations` | Creating Your Conversations... | Creando Tus Conversaciones... |
| `processAudio` | Process Audio | Procesar Audio |
| `noAudioFilesYet` | No Audio Files Yet | Sin Archivos de Audio Aún |
| `howDoesItWork` | How does it work? | ¿Cómo funciona? |
| `on` / `off` | On / Off | Activado / Desactivado |

### Foreground Service Notification
La notificación del servicio en segundo plano muestra el estado actual de la grabación:

| Estado | Inglés | Español | Cuándo se muestra |
|--------|--------|---------|-------------------|
| `waiting` | No device connected. Tap to record. | Sin dispositivo conectado. Toca para grabar. | Sin dispositivo, sin grabación |
| `device_connected` | Device connected - Ready to record | Dispositivo conectado - Listo para grabar | Dispositivo Omi conectado |
| `phone_mic` | Phone mic active - Ready to record | Micrófono activo - Listo para grabar | Usando micrófono del teléfono |
| `recording` | Recording... | Grabando... | Grabando (cualquier fuente) |
| `processing` | Processing audio... | Procesando audio... | Inicializando o procesando |
| `ready` | Transcription service ready | Servicio de transcripción listo | Fallback genérico |

#### Botones de Acción en Notificación
Cuando el estado es `waiting`, la notificación muestra dos botones de acción:

| Botón | ID | Inglés | Español | Acción |
|-------|-----|--------|---------|--------|
| Conectar | `connect_device` | Connect | Conectar | Navega a FindDevicesPage |
| Usar Mic | `use_phone_mic` | Use Mic | Usar Mic | Navega a FindDevicesPage |

Ambos botones navegan a la pantalla de conexión, donde el usuario puede elegir entre conectar un dispositivo Omi o usar el micrófono del teléfono.

**Arquitectura:**
```
CaptureProvider (main app)
    ↓ updateRecordingState() / _updateRecordingDevice()
    ↓
  _updateForegroundNotification(state)
    ↓
  FlutterForegroundTask.sendDataToTask({type, state, lang})
    ↓
_ForegroundFirstTaskHandler (background isolate)
    ↓ onReceiveData()
    ↓
  FlutterForegroundTask.updateService(notificationText, notificationButtons)

Usuario presiona botón en notificación
    ↓
_ForegroundFirstTaskHandler.onNotificationButtonPressed(id)
    ↓
FlutterForegroundTask.sendDataToMain({'action': id})
    ↓
main.dart: FlutterForegroundTask.receivePort?.listen()
    ↓
_handleNotificationAction() → Navigator.push(FindDevicesPage)
```

**Archivos**:
- `lib/utils/audio/foreground.dart` - TaskHandler con mapa de notificaciones y botones localizados
- `lib/providers/capture_provider.dart` - Envía actualizaciones de estado al servicio
- `lib/main.dart` - Escucha acciones de botones y navega

### Pantalla de Conexión de Dispositivo
La pantalla de búsqueda y conexión de dispositivos incluye una opción para usar el micrófono del teléfono:

| Clave | Inglés | Español |
|-------|--------|---------|
| `connect` | Connect | Conectar |
| `searchingForDevices` | Searching for devices... | Buscando dispositivos... |
| `devicesFoundNearby` | X DEVICE(S) FOUND NEARBY | X DISPOSITIVO(S) ENCONTRADO(S) CERCA |
| `pairingSuccessful` | PAIRING SUCCESSFUL | EMPAREJAMIENTO EXITOSO |
| `contactSupport` | Contact Support? | ¿Contactar soporte? |
| `orDivider` | or | o |
| `usePhoneMicrophone` | Use Phone Microphone | Usar Micrófono del Teléfono |
| `usePhoneMicrophoneDesc` | Record with your device's built-in microphone | Graba con el micrófono integrado de tu dispositivo |
| `connectLater` | Connect Later | Conectar después |

**Layout de FindDevicesPage:**
```
┌─────────────────────────────────────────┐
│     [Animación de búsqueda / Omi]       │
│     "Buscando dispositivos..."          │
│     [Lista de dispositivos]             │
│     [Contact Support?]                  │
├─────────────────────────────────────────┤
│              ───── o ─────              │
├─────────────────────────────────────────┤
│     ┌───────────────────────────────┐   │
│     │  📱 Usar Micrófono del        │   │
│     │     Teléfono                  │   │
│     │  Graba con el micrófono       │   │
│     │  integrado de tu dispositivo  │   │
│     └───────────────────────────────┘   │
│     [Conectar después]                  │
└─────────────────────────────────────────┘
```

Al presionar "Usar Micrófono del Teléfono":
1. Se marca `onboardingCompleted = true`
2. Se registra el evento `usePhoneMicrophoneOnboarding` en Mixpanel
3. Navega a `HomePageWrapper` (pantalla principal)

**Email de soporte**: `julio.gonzalez@maity.com.mx`

**Archivos**:
- `lib/pages/capture/connect.dart` - Pantalla de reconexión
- `lib/pages/onboarding/find_device/page.dart` - Pantalla principal con opción de micrófono
- `lib/pages/onboarding/find_device/found_devices.dart` - Lista de dispositivos

### Localización de Fechas
Las fechas se muestran en el idioma configurado usando el parámetro `locale` de `DateFormat`:

```dart
dateTimeFormat('MMM dd', date, locale: SharedPreferencesUtil().appLanguage)
// Español: "Ene 15"
// English: "Jan 15"
```

**Archivos actualizados:**
- `lib/pages/conversations/widgets/date_list_item.dart` - Fechas en lista de conversaciones
- `lib/pages/conversation_detail/widgets.dart` - Fechas y horas en detalle
- `lib/utils/other/temp.dart` - `formatChatTimestamp()` para chat

**Formatos usados:**
| Formato | Español | Inglés |
|---------|---------|--------|
| `MMM dd` | Ene 15 | Jan 15 |
| `MMM d` | Ene 5 | Jan 5 |
| `MMM d, yyyy` | Ene 5, 2025 | Jan 5, 2025 |
| `h:mm a` | 3:45 PM | 3:45 PM |

### Communication Feedback (Detalle de Conversación)
El widget CommunicationFeedbackCard está completamente localizado:

**Archivos**:
- `lib/pages/conversation_detail/widgets.dart` - Widget CommunicationFeedbackCard

| Clave | Inglés | Español |
|-------|--------|---------|
| `communicationFeedbackTitle` | Communication Feedback | Feedback de Comunicación |
| `analyzeCommunicationStyle` | Analyze your communication style... | Analiza tu estilo de comunicación... |
| `generateFeedback` | Generate Feedback | Generar Feedback |
| `couldNotRegenerateFeedback` | Could not regenerate feedback | No se pudo regenerar el feedback |
| `strengths` | Strengths | Fortalezas |
| `areasToImprove` | Areas to Improve | Áreas de Mejora |
| `clarity` | Clarity | Claridad |
| `structure` | Structure | Estructura |
| `callsToAction` | Calls to Action | Llamados a Acción |
| `objectionHandling` | Objection Handling | Manejo de Objeciones |
| `observations` | Observations | Observaciones |
| `communicationMetrics` | Communication Metrics | Métricas de Comunicación |
| `butCounter` | "But" | "Pero" |
| `fillerWordsLabel` | Filler Words | Muletillas |
| `objectionsLabel` | Objections | Objeciones |
| `detectedFillerWords` | Detected filler words | Muletillas detectadas |
| `objectionsReceived` | Objections received | Objeciones recibidas |
| `objectionsMade` | Objections made | Objeciones hechas |

### Action Items Page
La página de Action Items está completamente localizada:

**Archivos**:
- `lib/pages/action_items/action_items_page.dart`
- `lib/pages/action_items/widgets/action_item_form_sheet.dart`

| Clave | Inglés | Español |
|-------|--------|---------|
| `toDos` | To-Do's | Pendientes |
| `toDoTab` / `doneTab` / `oldTab` | To Do / Done / Old | Pendiente / Hecho / Antiguo |
| `allCaughtUp` | 🎉 All caught up! | 🎉 ¡Al día! |
| `noCompletedItemsYet` | No completed items yet | Sin elementos completados aún |
| `deleteSelectedItems` | Delete Selected Items | Eliminar Elementos Seleccionados |
| `deleteActionItem` | Delete Action Item | Eliminar Elemento de Acción |
| `actionItemsDeleted` | {count} action item(s) deleted | {count} elemento(s) de acción eliminado(s) |
| `actionItemDeleted` | Action item "{description}" deleted | Elemento de acción "{description}" eliminado |
| `failedToDeleteActionItem` | Failed to delete action item | No se pudo eliminar el elemento de acción |
| `actionItemUpdated` | Action item updated | Elemento de acción actualizado |
| `actionItemCreated` | Action item created | Elemento de acción creado |
| `completed` | Completed | Completado |
| `markComplete` | Mark complete | Marcar completo |
| `whatNeedsToBeDone` | What needs to be done? | ¿Qué necesita hacerse? |
| `addDueDate` | Add due date | Agregar fecha límite |

### Chat Message Actions
El menú de acciones de mensajes del chat está completamente localizado:

**Archivos**:
- `lib/pages/chat/widgets/message_action_menu.dart`

| Clave | Inglés | Español |
|-------|--------|---------|
| `copy` | Copy | Copiar |
| `selectText` | Select Text | Seleccionar Texto |
| `share` | Share | Compartir |
| `notHelpful` | Not Helpful | No Útil |
| `report` | Report | Reportar |

### Diálogos de Conversación
Los diálogos de eliminación de conversación están localizados:

**Archivos**:
- `lib/pages/conversation_detail/page.dart`

| Clave | Inglés | Español |
|-------|--------|---------|
| `deleteConversation` | Delete Conversation? | ¿Eliminar Conversación? |
| `deleteConversationConfirmation` | Are you sure... This action cannot be undone. | ¿Estás seguro... Esta acción no se puede deshacer. |
| `unableToDeleteConversation` | Unable to Delete Conversation | No se Puede Eliminar la Conversación |
| `checkInternetAndRetry` | Please check your internet... | Por favor verifica tu conexión... |
| `contentCopiedToClipboard` | Content copied to clipboard | Contenido copiado al portapapeles |

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

### Carga de Segmentos en Detalle de Conversación
Cuando el usuario abre el detalle de una conversación desde la lista:

1. `ConversationProvider.getConversations()` obtiene conversaciones **SIN segmentos** (optimización)
2. `conversation.transcriptSegments` está vacío → tab de transcripción deshabilitado
3. `ConversationDetailProvider.initConversation()` detecta lista vacía
4. Llama `_loadConversationSegments()` → `OmiSupabaseService.getConversation()`
5. Backend retorna conversación **CON segmentos**
6. `OmiSegment.toTranscriptSegment()` convierte cada segmento
7. Tab de transcripción se habilita al tener segmentos

**Ubicación**: `lib/pages/conversation_detail/conversation_detail_provider.dart:283-310`

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
| `/v2/messages` | POST | Chat con Maity (function calling para acceso a conversaciones) |
| `/v1/feedback/submit` | POST | Enviar feedback (comment/bug/suggestion) |
| `/v1/feedback/list` | GET | Listar feedback (solo developers @asertio.mx) |
| `/v1/feedback/my` | GET | Ver feedback propio del usuario |

## User Feedback System

Sistema de feedback para que los usuarios envíen comentarios, reportes de bugs y sugerencias.

### Arquitectura
```
Flutter (FeedbackPage) → Vercel (/v1/feedback/*) → Supabase (maity.user_feedback)
```

### Tipos de Feedback
| Tipo | Descripción | Icono |
|------|-------------|-------|
| `comment` | Comentario general | 💬 Azul |
| `bug` | Reporte de error | 🐛 Rojo |
| `suggestion` | Sugerencia de mejora | 💡 Naranja |

### Archivos del Sistema
- `api/routers/feedback.py` - Endpoints FastAPI (submit, list, my)
- `lib/services/feedback_service.dart` - Cliente Flutter
- `lib/pages/settings/feedback_page.dart` - Formulario de feedback
- `lib/pages/settings/feedback_list_page.dart` - Lista de feedback (developer)

### Flujo de Feedback
1. Usuario abre Settings → Send Feedback
2. Selecciona tipo (Comentario/Bug/Sugerencia)
3. Escribe mensaje y envía
4. Backend guarda en `maity.user_feedback` con info de dispositivo y versión
5. Developers (@asertio.mx) pueden ver todos los feedback en "Feedback Received"

### Permisos
- **Todos los usuarios**: Enviar feedback, ver su propio feedback
- **Developers (@asertio.mx)**: Ver todos los feedback de todos los usuarios

## Chat Agent (Maity)

Sistema de chat con acceso a las conversaciones del usuario mediante function calling de OpenAI.

### Arquitectura
```
Flutter (ChatPage) → Vercel (/v2/messages) → OpenAI (gpt-4o-mini + function calling) → Supabase
```

### Tools Disponibles (8 herramientas)

| Tool | Descripción | Uso típico |
|------|-------------|------------|
| `buscar_conversaciones` | Buscar por rango de fechas | "¿De qué hablé ayer?" |
| `obtener_conversacion` | Ver detalles completos con transcripción | Ver una conversación específica |
| `buscar_semantico` | Búsqueda por tema o contenido | "Conversaciones sobre el proyecto X" |
| `resumen_dia` | Resumen completo del día con métricas | "¿Qué hice hoy?" |
| `obtener_action_items` | Lista de tareas pendientes | "Mis pendientes" |
| `buscar_por_categoria` | Filtrar por categoría | "Conversaciones de trabajo" |
| `estadisticas_uso` | Métricas por período (today, weekly, monthly, yearly, all) | "Mis estadísticas del mes" |
| `feedback_comunicacion` | Análisis del estilo de comunicación | "¿Cómo me comunico?" |

### Quick Actions (UI)

La página de chat muestra 4 acciones rápidas cuando está vacía:

| Acción | Mensaje enviado |
|--------|-----------------|
| Resumen de hoy | "¿Qué hice hoy?" |
| Mis pendientes | "¿Cuáles son mis tareas pendientes?" |
| Mis estadísticas | "¿Cuáles son mis estadísticas del mes?" |
| Cómo me comunico | "¿Cómo es mi estilo de comunicación?" |

### Archivos del Sistema
- `api/routers/messages.py` - Endpoint /v2/messages + definición de tools
- `api/services/supabase_client.py` - Funciones de base de datos para tools
- `lib/pages/chat/page.dart` - UI de chat con quick actions
- `lib/providers/message_provider.dart` - Estado del chat

### System Prompt

El chat agent usa un system prompt detallado que incluye:
- Capacidades del asistente
- Lista de herramientas disponibles
- Categorías válidas para filtrar
- Reglas de respuesta (español, conciso, formato claro)
- Fecha actual para consultas relativas

### Flujo del Function Calling Loop

El endpoint `/v2/messages` implementa un loop de function calling correcto:

```python
# Flujo correcto (mantiene contexto de tools)
for iteration in range(5):
    response = await client.chat.completions.create(
        model="gpt-4o-mini",
        messages=messages,
        tools=TOOLS,           # ← SIEMPRE incluye tools
        tool_choice="auto",
    )

    if not assistant_message.tool_calls:
        # Streaming directo del contenido (no llamada extra)
        for chunk in content:
            yield chunk
        break

    # Ejecutar tools y agregar resultados a messages...

# Si loop se agota sin respuesta (edge case):
# Llamada con tools=TOOLS + tool_choice="none" (mantiene contexto)
```

**Importante**: NO hacer llamada extra sin tools después del loop.
Una llamada sin `tools=TOOLS` pierde el contexto de las herramientas ejecutadas
y resulta en respuestas genéricas.

**Ubicación**: `api/routers/messages.py:530-616`

### Patrón de Respuesta Estandarizado

Todas las funciones de `supabase_client.py` usadas por el chat agent retornan un formato estandarizado:

```python
# Éxito
{
    "success": True,
    "error": None,
    "data": {...}  # datos específicos de la función
}

# Error
{
    "success": False,
    "error": "Descripción del error en español",
    "data": None  # o valores vacíos por defecto
}
```

**Funciones con patrón estandarizado:**
- `get_user_metrics()` - Estadísticas de uso
- `get_day_summary()` - Resumen del día
- `get_action_items()` - Action items
- `search_by_category()` - Búsqueda por categoría
- `get_communication_feedback_aggregate()` - Feedback de comunicación

### Manejo de Errores en Chat

**ejecutar_tool() con try-except global:**
La función `ejecutar_tool()` en `messages.py` captura cualquier error inesperado:

```python
try:
    # ejecutar herramienta
    return json.dumps(result)
except Exception as e:
    print(f"[Messages] ERROR in ejecutar_tool({tool_name}): {e}")
    return json.dumps({
        "success": False,
        "error": f"Error ejecutando {tool_name}: {str(e)}",
        "data": None
    })
```

**Logging de resultados:**
Después de ejecutar cada herramienta, se imprime un preview del resultado (primeros 500 chars) para debugging en Vercel logs.

### Manejo de Resultados en System Prompt

El system prompt incluye reglas específicas para manejar respuestas de herramientas:

**Reglas en SYSTEM_PROMPT (MANEJO DE RESULTADOS):**
- SIEMPRE verificar el campo `"success"` primero
- Si `"success": false` → Informar: "Hubo un problema: [error]"
- Si `"success": true` pero `"total": 0` → Informar claramente al usuario
- Si hay campo `"message"` → Incluirlo en la respuesta
- NUNCA preguntar "¿Te gustaría saber más?" sin mostrar información primero
- SIEMPRE mostrar datos encontrados ANTES de ofrecer opciones adicionales

**Campos `message` en respuestas de herramientas:**

| Función | Campo message (cuando vacío) |
|---------|------------------------------|
| `buscar_conversaciones_db()` | "No encontré conversaciones entre {fecha_inicio} y {fecha_fin}" |
| `buscar_semantico_db()` | "No encontré conversaciones relacionadas con '{query}'" |

**Ubicación**: `api/routers/messages.py:70-77` (system prompt) y `api/services/supabase_client.py` (funciones)

## Backend (Monorepo)
Codigo en `C:\OMI\api\` (misma carpeta que Flutter app):
- `api/index.py` - FastAPI entry point
- `api/routers/omi.py` - Endpoints OMI para Supabase
- `api/routers/metrics.py` - Endpoints de métricas de uso (Supabase)
- `api/routers/feedback.py` - Endpoints de feedback de usuarios
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
- `lib/pages/conversation_detail/page.dart` - Delete, action items
- `lib/pages/onboarding/wrapper.dart` - Device connection flow

### Reglas
1. Siempre verificar `mounted` antes y después de awaits en StatefulWidget
2. Capturar Navigator, ScaffoldMessenger, Providers ANTES del await
3. No usar `context.read<>()` después de un await sin verificar mounted
4. Para callbacks en widgets stateless, usar el context del builder

## Documentación Adicional

- `docs/CHAT_AGENT_DIFFERENCES.md` - Comparación detallada del chat agent entre Accounting y OMI (tools, prompts, providers)
- `docs/google-sign-in-setup.md` - Configuración de Google Sign-In para Supabase Auth
