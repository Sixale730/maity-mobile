import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:omi/backend/http/api/users.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/app.dart';
import 'package:omi/backend/schema/geolocation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/main.dart';
import 'package:omi/pages/apps/app_detail/app_detail.dart';
import 'package:omi/pages/chat/page.dart';
import 'package:omi/pages/action_items/action_items_page.dart';
import 'package:omi/pages/conversations/conversations_page.dart';
import 'package:omi/pages/memories/page.dart';
import 'package:omi/pages/settings/data_privacy_page.dart';
import 'package:omi/pages/settings/settings_drawer.dart';
import 'package:omi/pages/settings/usage_page.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/connectivity_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/audio/foreground.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:omi/widgets/upgrade_alert.dart';
import 'package:provider/provider.dart';
import 'package:upgrader/upgrader.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/utils/enums.dart';

import 'package:omi/pages/conversation_capturing/page.dart';
import 'package:omi/services/transcript_recovery_service.dart';
import 'package:omi/widgets/recovery_dialog.dart';

import 'widgets/battery_info_widget.dart';

class HomePageWrapper extends StatefulWidget {
  final String? navigateToRoute;
  const HomePageWrapper({super.key, this.navigateToRoute});

  @override
  State<HomePageWrapper> createState() => _HomePageWrapperState();
}

class _HomePageWrapperState extends State<HomePageWrapper> {
  String? _navigateToRoute;

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        context.read<DeviceProvider>().periodicConnect('coming from HomePageWrapper', boundDeviceOnly: true);
      }
      if (SharedPreferencesUtil().notificationsEnabled) {
        NotificationService.instance.register();
        NotificationService.instance.saveNotificationToken();
      }
    });
    _navigateToRoute = widget.navigateToRoute;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return HomePage(navigateToRoute: _navigateToRoute);
  }
}

class HomePage extends StatefulWidget {
  final String? navigateToRoute;
  const HomePage({super.key, this.navigateToRoute});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, TickerProviderStateMixin {
  ForegroundUtil foregroundUtil = ForegroundUtil();
  List<Widget> screens = [Container(), const SizedBox(), const SizedBox(), const SizedBox()];

  final _upgrader = MyUpgrader(debugLogging: false, debugDisplayOnce: false);
  bool scriptsInProgress = false;

  final GlobalKey<State<ConversationsPage>> _conversationsPageKey = GlobalKey<State<ConversationsPage>>();
  final GlobalKey<State<ActionItemsPage>> _actionItemsPageKey = GlobalKey<State<ActionItemsPage>>();
  final GlobalKey<State<MemoriesPage>> _memoriesPageKey = GlobalKey<State<MemoriesPage>>();
  final GlobalKey<State<UsagePage>> _usagePageKey = GlobalKey<State<UsagePage>>();
  late final List<Widget> _pages;

  void _initiateApps() {
    context.read<AppProvider>().getApps();
    context.read<AppProvider>().getPopularApps();
  }

  void _scrollToTop(int pageIndex) {
    switch (pageIndex) {
      case 0:
        final conversationsState = _conversationsPageKey.currentState;
        if (conversationsState != null) {
          (conversationsState as dynamic).scrollToTop();
        }
        break;
      case 1:
        final actionItemsState = _actionItemsPageKey.currentState;
        if (actionItemsState != null) {
          (actionItemsState as dynamic).scrollToTop();
        }
        break;
      case 2:
        // MemoriesPage - could add scroll controller if needed
        break;
      case 3:
        // UsagePage doesn't have a scroll controller
        break;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    String event = '';
    if (state == AppLifecycleState.paused) {
      event = 'App is paused';
    } else if (state == AppLifecycleState.resumed) {
      event = 'App is resumed';

      // Reload convos
      if (mounted) {
        Provider.of<ConversationProvider>(context, listen: false).refreshConversations();
        Provider.of<CaptureProvider>(context, listen: false).refreshInProgressConversations();
      }
    } else if (state == AppLifecycleState.hidden) {
      event = 'App is hidden';
    } else if (state == AppLifecycleState.detached) {
      event = 'App is detached';
    } else {
      return;
    }
    debugPrint(event);
    PlatformManager.instance.crashReporter.logInfo(event);
  }

  ///Screens with respect to subpage
  final Map<String, Widget> screensWithRespectToPath = {
    '/facts': const MemoriesPage(),
  };
  bool? previousConnection;

  void _onReceiveTaskData(dynamic data) async {
    if (data is! Map<String, dynamic>) return;
    if (!(data.containsKey('latitude') && data.containsKey('longitude'))) return;
    await updateUserGeolocation(
      geolocation: Geolocation(
        latitude: data['latitude'],
        longitude: data['longitude'],
        accuracy: data['accuracy'],
        altitude: data['altitude'],
        time: DateTime.parse(data['time']).toUtc(),
      ),
    );
  }

  @override
  void initState() {
    _pages = [
      ConversationsPage(key: _conversationsPageKey),
      ActionItemsPage(key: _actionItemsPageKey),
      MemoriesPage(key: _memoriesPageKey),
      UsagePage(key: _usagePageKey),
    ];
    SharedPreferencesUtil().onboardingCompleted = true;

    // Navigate uri
    Uri? navigateToUri;
    var pageAlias = "home";
    var homePageIdx = 0;
    String? detailPageId;

    if (widget.navigateToRoute != null && widget.navigateToRoute!.isNotEmpty) {
      navigateToUri = Uri.tryParse("http://localhost.com${widget.navigateToRoute!}");
      debugPrint("initState ${navigateToUri?.pathSegments.join("...")}");
      var segments = navigateToUri?.pathSegments ?? [];
      if (segments.isNotEmpty) {
        pageAlias = segments[0];
      }
      if (segments.length > 1) {
        detailPageId = segments[1];
      }

      switch (pageAlias) {
        case "action-items":
        case "tasks":
        case "todos":
          homePageIdx = 1;
          break;
        case "memories":
        case "facts":
          homePageIdx = 2;
          break;
        case "insights":
        case "usage":
          homePageIdx = 3;
          break;
        case "apps":
          homePageIdx = 4;
          break;
      }
    }

    // Home controller
    context.read<HomeProvider>().selectedIndex = homePageIdx;
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _initiateApps();

      // ForegroundUtil.requestPermissions();
      if (!PlatformService.isDesktop) {
        await ForegroundUtil.initializeForegroundService();
        await ForegroundUtil.startForegroundTask();
      }
      if (mounted) {
        await Provider.of<HomeProvider>(context, listen: false).setUserPeople();
      }
      if (mounted) {
        await Provider.of<CaptureProvider>(context, listen: false)
            .streamDeviceRecording(device: Provider.of<DeviceProvider>(context, listen: false).connectedDevice);
      }

      // Navigate
      switch (pageAlias) {
        case "apps":
          if (detailPageId != null && detailPageId.isNotEmpty) {
            // Capture references before async operation
            final appProvider = context.read<AppProvider>();
            final navigator = Navigator.of(context);

            var app = await appProvider.getAppFromId(detailPageId);
            if (app != null && mounted) {
              navigator.push(
                MaterialPageRoute(
                  builder: (context) => AppDetailPage(app: app),
                ),
              );
            }
          }
          break;
        case "chat":
          debugPrint('inside chat alias $detailPageId');
          if (detailPageId != null && detailPageId.isNotEmpty) {
            var appId = detailPageId != "omi" ? detailPageId : ''; // omi ~ no select
            if (mounted) {
              // Capture references before async operations
              var appProvider = Provider.of<AppProvider>(context, listen: false);
              var messageProvider = Provider.of<MessageProvider>(context, listen: false);
              App? selectedApp;
              if (appId.isNotEmpty) {
                selectedApp = await appProvider.getAppFromId(appId);
              }
              if (!mounted) break;
              appProvider.setSelectedChatAppId(appId);
              await messageProvider.refreshMessages();
              if (!mounted) break;
              if (messageProvider.messages.isEmpty) {
                messageProvider.sendInitialAppMessage(selectedApp);
              }
            }
          } else {
            if (mounted) {
              // Capture reference before async operation
              final messageProvider = Provider.of<MessageProvider>(context, listen: false);
              await messageProvider.refreshMessages();
            }
          }
          // Navigate to chat page directly since it's no longer in the tab bar
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ChatPage(isPivotBottom: false),
                ),
              );
            }
          });
          break;
        case "settings":
          // Use context from the current widget instead of navigator key for bottom sheet
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              SettingsDrawer.show(context);
            }
          });
          if (detailPageId == 'data-privacy') {
            MyApp.navigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (context) => const DataPrivacyPage(),
              ),
            );
          }
          break;
        case "facts":
          // Memories is now tab index 1, already handled by homePageIdx
          break;
        default:
      }
    });

    _listenToMessagesFromNotification();
    super.initState();

    // After init
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);

    // Check for interrupted recording sessions after a short delay
    // to allow providers to initialize
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _checkForInterruptedSession();
        }
      });
    });
  }

  /// Check for interrupted recording sessions and offer recovery
  Future<void> _checkForInterruptedSession() async {
    try {
      final interruptedSession = await TranscriptRecoveryService.checkForInterruptedSession();

      if (interruptedSession != null && mounted) {
        debugPrint('[HomePage] Found interrupted session: ${interruptedSession.segmentCount} segments');

        RecoveryDialog.show(
          context: context,
          session: interruptedSession,
          onRecover: () async {
            if (!mounted) return;

            // Show loading indicator
            final l10n = AppLocalizations.of(context);
            final scaffoldMessenger = ScaffoldMessenger.of(context);

            scaffoldMessenger.showSnackBar(
              SnackBar(
                content: Text(l10n?.recoveryInProgress ?? 'Recovering conversation...'),
                duration: const Duration(seconds: 30),
              ),
            );

            // Recover the session
            final captureProvider = Provider.of<CaptureProvider>(context, listen: false);
            final success = await captureProvider.recoverInterruptedSession(
              interruptedSession.segments,
              interruptedSession.startedAt,
            );

            if (!mounted) return;

            scaffoldMessenger.hideCurrentSnackBar();

            if (success) {
              scaffoldMessenger.showSnackBar(
                SnackBar(
                  content: Text(l10n?.recoverySuccess ?? 'Conversation recovered successfully'),
                  backgroundColor: Colors.green,
                ),
              );
              // Refresh conversations list
              Provider.of<ConversationProvider>(context, listen: false).refreshConversations();
            } else {
              scaffoldMessenger.showSnackBar(
                SnackBar(
                  content: Text(l10n?.recoveryFailed ?? 'Failed to recover conversation'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          },
          onDiscard: () async {
            // Clear the recovery data
            await TranscriptRecoveryService.clearRecoveryData();
            debugPrint('[HomePage] User discarded interrupted session');
          },
        );
      }
    } catch (e) {
      debugPrint('[HomePage] Error checking for interrupted session: $e');
    }
  }

  void _listenToMessagesFromNotification() {
    NotificationService.instance.listenForServerMessages.listen((message) {
      if (mounted) {
        var selectedApp = Provider.of<AppProvider>(context, listen: false).getSelectedApp();
        if (selectedApp == null || message.appId == selectedApp.id) {
          Provider.of<MessageProvider>(context, listen: false).addMessage(message);
        }
        // chatPageKey.currentState?.scrollToBottom();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MyUpgradeAlert(
      upgrader: _upgrader,
      dialogStyle: Platform.isIOS ? UpgradeDialogStyle.cupertino : UpgradeDialogStyle.material,
      child: Consumer<ConnectivityProvider>(
        builder: (ctx, connectivityProvider, child) {
          bool isConnected = connectivityProvider.isConnected;
          previousConnection ??= true;

          if (previousConnection != isConnected &&
              connectivityProvider.isInitialized &&
              connectivityProvider.previousConnection != isConnected) {
            previousConnection = isConnected;
            if (!isConnected) {
              // Capture references before async delay
              final scaffoldMessenger = ScaffoldMessenger.of(ctx);
              final noInternetText = AppLocalizations.of(ctx)?.noInternetConnection ?? 'No internet connection. Please check your connection.';
              final dismissText = AppLocalizations.of(ctx)?.dismiss ?? 'Dismiss';

              Future.delayed(const Duration(seconds: 2), () {
                if (mounted && !connectivityProvider.isConnected) {
                  scaffoldMessenger.showMaterialBanner(
                    MaterialBanner(
                      content: Text(
                        noInternetText,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      backgroundColor: const Color(0xFF424242), // Dark gray instead of red
                      leading: const Icon(Icons.wifi_off, color: Colors.white70),
                      actions: [
                        TextButton(
                          onPressed: () {
                            scaffoldMessenger.hideCurrentMaterialBanner();
                          },
                          child: Text(dismissText, style: const TextStyle(color: Colors.white70)),
                        ),
                      ],
                    ),
                  );
                }
              });
            } else {
              // Capture references before async operations
              final scaffoldMessenger = ScaffoldMessenger.of(ctx);
              final internetRestoredText = AppLocalizations.of(ctx)?.internetRestored ?? 'Internet connection is restored.';
              final dismissText = AppLocalizations.of(ctx)?.dismiss ?? 'Dismiss';
              final conversationProvider = ctx.read<ConversationProvider>();
              final messageProvider = ctx.read<MessageProvider>();

              Future.delayed(Duration.zero, () {
                if (mounted) {
                  scaffoldMessenger.hideCurrentMaterialBanner();
                  scaffoldMessenger.showMaterialBanner(
                    MaterialBanner(
                      content: Text(
                        internetRestoredText,
                        style: const TextStyle(color: Colors.white),
                      ),
                      backgroundColor: const Color(0xFF2E7D32), // Dark green instead of bright green
                      leading: const Icon(Icons.wifi, color: Colors.white),
                      actions: [
                        TextButton(
                          onPressed: () {
                            if (mounted) {
                              scaffoldMessenger.hideCurrentMaterialBanner();
                            }
                          },
                          child: Text(dismissText, style: const TextStyle(color: Colors.white)),
                        ),
                      ],
                      onVisible: () => Future.delayed(const Duration(seconds: 3), () {
                        if (mounted) {
                          scaffoldMessenger.hideCurrentMaterialBanner();
                        }
                      }),
                    ),
                  );
                }

                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  if (mounted) {
                    if (conversationProvider.conversations.isEmpty) {
                      await conversationProvider.getInitialConversations();
                    } else {
                      // Force refresh when internet connection is restored
                      await conversationProvider.forceRefreshConversations();
                    }
                    if (!mounted) return;
                    if (messageProvider.messages.isEmpty) {
                      await messageProvider.refreshMessages();
                    }
                  }
                });
              });
            }
          }
          return child!;
        },
        child: Consumer<HomeProvider>(
          builder: (context, homeProvider, _) {
            return Scaffold(
              backgroundColor: Theme.of(context).colorScheme.primary,
              appBar: homeProvider.selectedIndex == 4 ? null : _buildAppBar(context),
              body: DefaultTabController(
                length: 4,
                initialIndex: homeProvider.selectedIndex,
                child: GestureDetector(
                  onTap: () {
                    primaryFocus?.unfocus();
                    // context.read<HomeProvider>().memoryFieldFocusNode.unfocus();
                    // context.read<HomeProvider>().chatFieldFocusNode.unfocus();
                  },
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          Expanded(
                            child: IndexedStack(
                              index: context.watch<HomeProvider>().selectedIndex,
                              children: _pages,
                            ),
                          ),
                        ],
                      ),
                      Consumer2<HomeProvider, DeviceProvider>(
                        builder: (context, home, deviceProvider, child) {
                          if (home.isChatFieldFocused ||
                              home.isConvoSearchFieldFocused) {
                            return const SizedBox.shrink();
                          } else {
                            // Check if OMI device is connected
                            bool isOmiDeviceConnected =
                                deviceProvider.isConnected && deviceProvider.connectedDevice != null;

                            return Stack(
                              children: [
                                // Bottom Navigation Bar
                                Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    width: double.infinity,
                                    height: 100,
                                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        stops: [0.0, 0.30, 1.0],
                                        colors: [
                                          Colors.transparent,
                                          Color.fromARGB(255, 15, 15, 15),
                                          Color.fromARGB(255, 15, 15, 15),
                                        ],
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        // Home tab
                                        Expanded(
                                          child: InkWell(
                                            onTap: () {
                                              HapticFeedback.mediumImpact();
                                              MixpanelManager().bottomNavigationTabClicked('Home');
                                              primaryFocus?.unfocus();
                                              if (home.selectedIndex == 0) {
                                                _scrollToTop(0);
                                                return;
                                              }
                                              home.setIndex(0);
                                            },
                                            child: SizedBox(
                                              height: 90,
                                              child: Center(
                                                child: Icon(
                                                  FontAwesomeIcons.house,
                                                  color: home.selectedIndex == 0 ? Colors.white : Colors.grey,
                                                  size: 22,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        // To-Do's tab
                                        Expanded(
                                          child: InkWell(
                                            onTap: () {
                                              HapticFeedback.mediumImpact();
                                              MixpanelManager().bottomNavigationTabClicked('ToDos');
                                              primaryFocus?.unfocus();
                                              if (home.selectedIndex == 1) {
                                                _scrollToTop(1);
                                                return;
                                              }
                                              home.setIndex(1);
                                            },
                                            child: SizedBox(
                                              height: 90,
                                              child: Center(
                                                child: Icon(
                                                  FontAwesomeIcons.listCheck,
                                                  color: home.selectedIndex == 1 ? Colors.white : Colors.grey,
                                                  size: 22,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        // Center space for record button - only when no OMI device is connected
                                        if (!isOmiDeviceConnected) const SizedBox(width: 80),
                                        // Memories tab
                                        Expanded(
                                          child: InkWell(
                                            onTap: () {
                                              HapticFeedback.mediumImpact();
                                              MixpanelManager().bottomNavigationTabClicked('Memories');
                                              primaryFocus?.unfocus();
                                              if (home.selectedIndex == 2) {
                                                _scrollToTop(2);
                                                return;
                                              }
                                              home.setIndex(2);
                                            },
                                            child: SizedBox(
                                              height: 90,
                                              child: Center(
                                                child: Icon(
                                                  FontAwesomeIcons.lightbulb,
                                                  color: home.selectedIndex == 2 ? Colors.white : Colors.grey,
                                                  size: 22,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        // Usage Insights tab
                                        Expanded(
                                          child: InkWell(
                                            onTap: () {
                                              HapticFeedback.mediumImpact();
                                              MixpanelManager().bottomNavigationTabClicked('Insights');
                                              primaryFocus?.unfocus();
                                              if (home.selectedIndex == 3) {
                                                _scrollToTop(3);
                                                return;
                                              }
                                              home.setIndex(3);
                                            },
                                            child: SizedBox(
                                              height: 90,
                                              child: Center(
                                                child: Icon(
                                                  FontAwesomeIcons.chartLine,
                                                  color: home.selectedIndex == 3 ? Colors.white : Colors.grey,
                                                  size: 22,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // Central Record Button - Only show when no OMI device is connected
                                if (!isOmiDeviceConnected)
                                  Positioned(
                                    left: MediaQuery.of(context).size.width / 2 - 40,
                                    bottom: 40, // Position it to protrude above the taller navbar (90px height)
                                    child: Consumer<CaptureProvider>(
                                      builder: (context, captureProvider, child) {
                                        bool isRecording = captureProvider.recordingState == RecordingState.record;
                                        bool isInitializing =
                                            captureProvider.recordingState == RecordingState.initialising;
                                        return GestureDetector(
                                          onTap: () async {
                                            HapticFeedback.heavyImpact();
                                            if (isInitializing) return;
                                            await _handleRecordButtonPress(context, captureProvider);
                                          },
                                          child: Container(
                                            width: 80,
                                            height: 80,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: isRecording ? Colors.red : const Color(0xFF485DF4),
                                              border: Border.all(
                                                color: Colors.black,
                                                width: 5,
                                              ),
                                            ),
                                            child: isInitializing
                                                ? const CircularProgressIndicator(
                                                    color: Colors.white,
                                                    strokeWidth: 2,
                                                  )
                                                : Icon(
                                                    isRecording ? FontAwesomeIcons.stop : FontAwesomeIcons.microphone,
                                                    color: Colors.white,
                                                    size: 24,
                                                  ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                // Remove the floating chat button - moving it to app bar
                              ],
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _handleRecordButtonPress(BuildContext context, CaptureProvider captureProvider) async {
    var recordingState = captureProvider.recordingState;

    if (recordingState == RecordingState.record) {
      // Stop recording and summarize conversation
      await captureProvider.stopStreamRecording();
      captureProvider.forceProcessingCurrentConversation();
      MixpanelManager().phoneMicRecordingStopped();
    } else if (recordingState == RecordingState.initialising) {
      // Already initializing, do nothing
      debugPrint('initialising, have to wait');
    } else {
      // Start recording directly without dialog
      await captureProvider.streamRecording();
      MixpanelManager().phoneMicRecordingStarted();

      // Navigate to conversation capturing page
      if (context.mounted) {
        var topConvoId = (captureProvider.conversationProvider?.conversations ?? []).isNotEmpty
            ? captureProvider.conversationProvider!.conversations.first.id
            : null;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ConversationCapturingPage(topConversationId: topConvoId),
          ),
        );
      }
    }
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const BatteryInfoWidget(),
          const SizedBox.shrink(),
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: Color(0xFF1F1F25),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    FontAwesomeIcons.gear,
                    size: 16,
                    color: Colors.white70,
                  ),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    MixpanelManager().pageOpened('Settings');
                    String language = SharedPreferencesUtil().userPrimaryLanguage;
                    bool hasSpeech = SharedPreferencesUtil().hasSpeakerProfile;
                    String transcriptModel = SharedPreferencesUtil().transcriptionModel;
                    SettingsDrawer.show(context);
                    if (language != SharedPreferencesUtil().userPrimaryLanguage ||
                        hasSpeech != SharedPreferencesUtil().hasSpeakerProfile ||
                        transcriptModel != SharedPreferencesUtil().transcriptionModel) {
                      if (context.mounted) {
                        context.read<CaptureProvider>().onRecordProfileSettingChanged();
                      }
                    }
                  },
                ),
              ),
              // Chat Button - Shows on all pages
              GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  MixpanelManager().bottomNavigationTabClicked('Chat');
                  // Navigate to chat page
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ChatPage(isPivotBottom: false),
                    ),
                  );
                },
                child: Container(
                  height: 36,
                  margin: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF485DF4).withValues(alpha: 0.3),
                        const Color(0xFF6B7BF7).withValues(alpha: 0.2),
                        const Color(0xFF485DF4).withValues(alpha: 0.3),
                        const Color(0xFF6B7BF7).withValues(alpha: 0.2),
                        const Color(0xFF485DF4).withValues(alpha: 0.3),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Container(
                    margin: const EdgeInsets.all(0.5),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF485DF4).withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(17.5),
                      border: Border.all(
                        color: const Color(0xFF485DF4).withValues(alpha: 0.3),
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          FontAwesomeIcons.solidComment,
                          size: 14,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          AppLocalizations.of(context)?.chat ?? 'Chat',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      elevation: 0,
      centerTitle: true,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ForegroundUtil.stopForegroundTask();
    super.dispose();
  }
}
