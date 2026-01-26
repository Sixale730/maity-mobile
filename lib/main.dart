import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:omi/firebase_options.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/core/app_shell.dart';
import 'package:omi/env/env.dart';
import 'package:omi/env/prod_env.dart';
import 'package:omi/pages/apps/providers/add_app_provider.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/pages/settings/ai_app_generator_provider.dart';
import 'package:omi/pages/payments/payment_method_provider.dart';
import 'package:omi/pages/persona/persona_provider.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/providers/auth_provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/connectivity_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/developer_mode_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/mcp_provider.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/providers/onboarding_provider.dart';
import 'package:omi/providers/task_integration_provider.dart';
import 'package:omi/providers/integration_provider.dart';
import 'package:omi/providers/people_provider.dart';
import 'package:omi/providers/speech_profile_provider.dart';
import 'package:omi/providers/sync_provider.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/providers/user_provider.dart';
import 'package:omi/providers/communication_provider.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/services/desktop_update_service.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/analytics/growthbook.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/pages/onboarding/find_device/page.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:window_manager/window_manager.dart';

/// Auto-configura Deepgram como proveedor de STT si no hay configuración previa
Future<void> _autoConfigureDeepgram() async {
  final prefs = SharedPreferencesUtil();
  final currentConfig = prefs.customSttConfig;

  // Solo configurar si no hay STT personalizado habilitado
  if (!currentConfig.isEnabled) {
    final deepgramKey = Env.deepgramApiKey;
    if (deepgramKey != null && deepgramKey.isNotEmpty) {
      final config = CustomSttConfig(
        provider: SttProvider.deepgramLive,
        apiKey: deepgramKey,
        language: 'es-419', // Español Latinoamericano
        model: 'nova-3',
      );
      await prefs.saveCustomSttConfig(config);
      debugPrint('[Maity] Deepgram auto-configurado como STT por defecto');
    }
  }
}

Future _init() async {
  // Env - Siempre usar ProdEnv ya que eliminamos flavors
  Env.init(ProdEnv());

  // Firebase initialization
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Pass all uncaught "fatal" errors from the framework to Crashlytics
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

  // Pass all uncaught asynchronous errors that aren't handled by the Flutter framework to Crashlytics
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  debugPrint('[Maity] Firebase initialized');

  FlutterForegroundTask.initCommunicationPort();

  // Service manager
  await ServiceManager.init();

  // Supabase
  if (Env.supabaseUrl != null && Env.supabaseAnonKey != null) {
    await Supabase.initialize(
      url: Env.supabaseUrl!,
      anonKey: Env.supabaseAnonKey!,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
    debugPrint('[Maity] Supabase inicializado');
  }

  await PlatformManager.initializeServices();
  await NotificationService.instance.initialize();

  await SharedPreferencesUtil.init();

  // Auto-configurar Deepgram como STT por defecto
  await _autoConfigureDeepgram();

  bool isAuth = (await AuthService.instance.getIdToken()) != null;
  if (isAuth) PlatformManager.instance.mixpanel.identify();
  if (PlatformService.isMobile) initOpus(await opus_flutter.load());

  await GrowthbookUtil.init();
  if (!PlatformService.isWindows) {
    ble.FlutterBluePlus.setOptions(restoreState: true);
    ble.FlutterBluePlus.setLogLevel(ble.LogLevel.info, color: true);
  }

  // Initialize desktop updater
  if (PlatformService.isDesktop) {
    await DesktopUpdateService().initialize();
  }

  await ServiceManager.instance().start();
  return;
}

void main() {
  runZonedGuarded(
    () async {
      // Ensure
      WidgetsFlutterBinding.ensureInitialized();
      if (PlatformService.isDesktop) {
        await windowManager.ensureInitialized();
        WindowOptions windowOptions = const WindowOptions(
          size: Size(1440, 900),
          minimumSize: Size(1000, 650),
          center: true,
          title: "Maity",
          titleBarStyle: TitleBarStyle.hidden,
        );
        windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.setAsFrameless();
          await windowManager.show();
          await windowManager.focus();
        });
      }

      await _init();
      runApp(const MyApp());
    },
    (error, stack) {
      debugPrint('Uncaught error: $error');
      debugPrint('Stack trace: $stack');
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static _MyAppState of(BuildContext context) => context.findAncestorStateOfType<_MyAppState>()!;

  // The navigator key is necessary to navigate using static methods
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Notifier para cambios de locale (permite rebuild sin perder estado)
  static final ValueNotifier<Locale> localeNotifier =
      ValueNotifier(Locale(SharedPreferencesUtil().appLanguage));

  /// Método para cambiar el idioma desde cualquier parte de la app
  static void changeLocale(String languageCode) {
    SharedPreferencesUtil().appLanguage = languageCode;
    localeNotifier.value = Locale(languageCode);
  }
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  /// Triggers a rebuild of the entire app (useful for locale changes)
  void rebuildApp() {
    setState(() {});
  }

  @override
  void initState() {
    NotificationUtil.initializeNotificationsEventListeners();
    NotificationUtil.initializeIsolateReceivePort();
    WidgetsBinding.instance.addObserver(this);
    if (SharedPreferencesUtil().devLogsToFileEnabled) {
      DebugLogManager.setEnabled(true);
    }

    // Auto-start macOS recording if enabled
    if (PlatformService.isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autoStartMacOSRecording();
      });
    }

    // Listen for foreground notification button actions
    _initForegroundTaskListener();

    super.initState();
  }

  void _initForegroundTaskListener() {
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
  }

  void _onReceiveTaskData(Object data) {
    debugPrint('[Foreground] Received data from task: $data');
    if (data is Map && data['action'] != null) {
      final action = data['action'];
      _handleNotificationAction(action);
    }
  }

  void _handleNotificationAction(String action) {
    debugPrint('[Foreground] Handling notification action: $action');
    final context = MyApp.navigatorKey.currentContext;
    if (context == null) {
      debugPrint('[Foreground] Navigator context is null, cannot navigate');
      return;
    }

    if (action == 'connect_device' || action == 'use_phone_mic') {
      // Navigate to FindDevicesPage where user can connect device or use phone mic
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: FindDevicesPage(
                goNext: () => Navigator.of(context).pop(),
                includeSkip: true,
                isFromOnboarding: false,
              ),
            ),
          ),
        ),
      );
    }
  }

  Future<void> _autoStartMacOSRecording() async {
    await Future.delayed(const Duration(seconds: 2));

    if (!SharedPreferencesUtil().autoRecordingEnabled) return;

    try {
      final context = MyApp.navigatorKey.currentContext;
      if (context == null) return;

      final captureProvider = Provider.of<CaptureProvider>(context, listen: false);
      if (captureProvider.recordingState == RecordingState.stop) {
        await captureProvider.streamSystemAudioRecording();
      }
    } catch (e) {
      debugPrint('[AutoRecord] Error: $e');
    }
  }

  void _deinit() {
    debugPrint("App > _deinit");
    ServiceManager.instance().deinit();
    ApiClient.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      _onAppPaused();
    } else if (state == AppLifecycleState.detached) {
      _deinit();
    }
  }

  void _onAppPaused() {
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
        providers: [
          ListenableProvider(create: (context) => ConnectivityProvider()),
          ChangeNotifierProvider(create: (context) => AuthenticationProvider()),
          ChangeNotifierProvider(create: (context) => ConversationProvider()),
          ListenableProvider(create: (context) => AppProvider()),
          ChangeNotifierProvider(create: (context) => PeopleProvider()),
          ChangeNotifierProvider(create: (context) => UsageProvider()),
          ChangeNotifierProvider(create: (context) => CommunicationProvider()),
          ChangeNotifierProxyProvider<AppProvider, MessageProvider>(
            create: (context) => MessageProvider(),
            update: (BuildContext context, value, MessageProvider? previous) =>
                (previous?..updateAppProvider(value)) ?? MessageProvider(),
          ),
          ChangeNotifierProxyProvider4<ConversationProvider, MessageProvider, PeopleProvider, UsageProvider,
              CaptureProvider>(
            create: (context) => CaptureProvider(),
            update: (BuildContext context, conversation, message, people, usage, CaptureProvider? previous) =>
                (previous?..updateProviderInstances(conversation, message, people, usage)) ?? CaptureProvider(),
          ),
          ChangeNotifierProxyProvider<CaptureProvider, DeviceProvider>(
            create: (context) => DeviceProvider(),
            update: (BuildContext context, captureProvider, DeviceProvider? previous) =>
                (previous?..setProviders(captureProvider)) ?? DeviceProvider(),
          ),
          ChangeNotifierProxyProvider<DeviceProvider, OnboardingProvider>(
            create: (context) => OnboardingProvider(),
            update: (BuildContext context, value, OnboardingProvider? previous) =>
                (previous?..setDeviceProvider(value)) ?? OnboardingProvider(),
          ),
          ListenableProvider(create: (context) => HomeProvider()),
          ChangeNotifierProxyProvider<DeviceProvider, SpeechProfileProvider>(
            create: (context) => SpeechProfileProvider(),
            update: (BuildContext context, device, SpeechProfileProvider? previous) =>
                (previous?..setProviders(device)) ?? SpeechProfileProvider(),
          ),
          ChangeNotifierProxyProvider2<AppProvider, ConversationProvider, ConversationDetailProvider>(
            create: (context) => ConversationDetailProvider(),
            update: (BuildContext context, app, conversation, ConversationDetailProvider? previous) =>
                (previous?..setProviders(app, conversation)) ?? ConversationDetailProvider(),
          ),
          ChangeNotifierProvider(create: (context) => DeveloperModeProvider()),
          ChangeNotifierProvider(create: (context) => McpProvider()),
          ChangeNotifierProxyProvider<AppProvider, AddAppProvider>(
            create: (context) => AddAppProvider(),
            update: (BuildContext context, value, AddAppProvider? previous) =>
                (previous?..setAppProvider(value)) ?? AddAppProvider(),
          ),
          ChangeNotifierProxyProvider<AppProvider, AiAppGeneratorProvider>(
            create: (context) => AiAppGeneratorProvider(),
            update: (BuildContext context, value, AiAppGeneratorProvider? previous) =>
                (previous?..setAppProvider(value)) ?? AiAppGeneratorProvider(),
          ),
          ChangeNotifierProvider(create: (context) => PaymentMethodProvider()),
          ChangeNotifierProvider(create: (context) => PersonaProvider()),
          ChangeNotifierProvider(create: (context) => MemoriesProvider()),
          ChangeNotifierProvider(create: (context) => UserProvider()),
          ChangeNotifierProvider(create: (context) => ActionItemsProvider()),
          ChangeNotifierProvider(create: (context) => SyncProvider()),
          ChangeNotifierProvider(create: (context) => TaskIntegrationProvider()),
          ChangeNotifierProvider(create: (context) => IntegrationProvider()),
        ],
        builder: (context, child) {
          return WithForegroundTask(
            child: ValueListenableBuilder<Locale>(
              valueListenable: MyApp.localeNotifier,
              builder: (context, locale, child) {
                return MaterialApp(
                  debugShowCheckedModeBanner: false,
                  title: 'Maity',
                  navigatorKey: MyApp.navigatorKey,
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  supportedLocales: const [
                    Locale('es'), // Spanish (default)
                    Locale('en'), // English
                  ],
                  locale: locale, // Usar el valor del notifier
                  theme: ThemeData(
                    useMaterial3: false,
                    colorScheme: const ColorScheme.dark(
                      primary: Colors.black,
                      secondary: Color(0xFFFF0050), // Maity Rosa Principal
                      surface: Colors.black38,
                    ),
                    snackBarTheme: const SnackBarThemeData(
                      backgroundColor: Color(0xFF1F1F25),
                      contentTextStyle: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.w500),
                    ),
                    textTheme: TextTheme(
                      titleLarge: const TextStyle(fontSize: 18, color: Colors.white),
                      titleMedium: const TextStyle(fontSize: 16, color: Colors.white),
                      bodyMedium: const TextStyle(fontSize: 14, color: Colors.white),
                      labelMedium: TextStyle(fontSize: 12, color: Colors.grey.shade200),
                    ),
                    textSelectionTheme: const TextSelectionThemeData(
                      cursorColor: Colors.white,
                      selectionColor: Color(0xFFFF0050), // Maity Rosa Principal
                      selectionHandleColor: Colors.white,
                    ),
                    cupertinoOverrideTheme: const CupertinoThemeData(
                      primaryColor: Colors.white, // Controls the selection handles on iOS
                    ),
                  ),
                  themeMode: ThemeMode.dark,
                  builder: (context, child) {
                    FlutterError.onError = (FlutterErrorDetails details) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        Logger.instance.talker.handle(details.exception, details.stack);
                        DebugLogManager.logError(details.exception, details.stack, 'FlutterError');
                      });
                    };
                    ErrorWidget.builder = (errorDetails) {
                      return CustomErrorWidget(errorMessage: errorDetails.exceptionAsString());
                    };
                    return child!;
                  },
                  home: TalkerWrapper(
                    talker: Logger.instance.talker,
                    options: const TalkerWrapperOptions(
                      enableErrorAlerts: false,
                      enableExceptionAlerts: false,
                    ),
                    child: const AppShell(),
                  ),
                );
              },
            ),
          );
        });
  }
}

class CustomErrorWidget extends StatelessWidget {
  final String errorMessage;

  const CustomErrorWidget({super.key, required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.red,
              size: 50.0,
            ),
            const SizedBox(height: 10.0),
            const Text(
              'Something went wrong! Please try again later.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10.0),
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.all(16),
              height: 200,
              decoration: BoxDecoration(
                color: const Color.fromARGB(255, 63, 63, 63),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                errorMessage,
                textAlign: TextAlign.start,
                style: const TextStyle(fontSize: 16.0),
              ),
            ),
            const SizedBox(height: 10.0),
            SizedBox(
              width: 210,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: errorMessage));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Error message copied to clipboard'),
                    ),
                  );
                },
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('Copy error message'),
                    SizedBox(width: 10),
                    Icon(Icons.copy_rounded),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
