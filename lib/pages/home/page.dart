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
import 'package:omi/pages/dashboard/dashboard_page.dart';
import 'package:omi/pages/memories/page.dart';
import 'package:omi/pages/settings/data_privacy_page.dart';
import 'package:omi/pages/settings/settings_drawer.dart';
import 'package:omi/pages/settings/usage_page.dart';
import 'package:omi/pages/home/widgets/app_navigation_drawer.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/connectivity_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/providers/daily_report_provider.dart';
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
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  ForegroundUtil foregroundUtil = ForegroundUtil();
  List<Widget> screens = [Container(), const SizedBox(), const SizedBox(), const SizedBox()];

  final _upgrader = MyUpgrader(debugLogging: false, debugDisplayOnce: false);
  bool scriptsInProgress = false;

  final GlobalKey<State<DashboardPage>> _dashboardPageKey = GlobalKey<State<DashboardPage>>();
  final GlobalKey<State<ConversationsPage>> _conversationsPageKey = GlobalKey<State<ConversationsPage>>();
  final GlobalKey<State<ActionItemsPage>> _actionItemsPageKey = GlobalKey<State<ActionItemsPage>>();
  final GlobalKey<State<UsagePage>> _usagePageKey = GlobalKey<State<UsagePage>>();
  late final List<Widget> _pages;

  void _initiateApps() {
    context.read<AppProvider>().getApps();
    context.read<AppProvider>().getPopularApps();
  }

  void _scrollToTop(int navIndex) {
    switch (navIndex) {
      case 0:
        final dashboardState = _dashboardPageKey.currentState;
        if (dashboardState != null) {
          (dashboardState as dynamic).scrollToTop();
        }
        break;
      case 1:
        final conversationsState = _conversationsPageKey.currentState;
        if (conversationsState != null) {
          (conversationsState as dynamic).scrollToTop();
        }
        break;
      case 3:
        final actionItemsState = _actionItemsPageKey.currentState;
        if (actionItemsState != null) {
          (actionItemsState as dynamic).scrollToTop();
        }
        break;
      case 4:
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
      DashboardPage(key: _dashboardPageKey),
      ConversationsPage(key: _conversationsPageKey),
      ActionItemsPage(key: _actionItemsPageKey),
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
        case "conversations":
          homePageIdx = 1;
          break;
        case "action-items":
        case "tasks":
        case "todos":
          homePageIdx = 3;
          break;
        case "insights":
        case "usage":
          homePageIdx = 4;
          break;
        case "apps":
          homePageIdx = 4;
          break;
        case "memories":
        case "facts":
          // Memories is accessed via drawer push, default to home
          homePageIdx = 0;
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
        case "memories":
        case "facts":
          // Memories is no longer in the tab bar, push it
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.push(context, MaterialPageRoute(builder: (context) => const MemoriesPage()));
            }
          });
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
      // Check for new daily report after 3s
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          _checkForDailyReport();
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
              draftConversationId: interruptedSession.draftConversationId,
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

  Future<void> _checkForDailyReport() async {
    try {
      final provider = context.read<DailyReportProvider>();
      await provider.fetchLatestReport();
      if (!mounted) return;

      final report = provider.latestReport;
      if (report != null && report.isToday) {
        // Check if already dismissed today
        final lastDismissed = SharedPreferencesUtil().lastDismissedDailyReport;
        if (lastDismissed == report.reportDate) return;

        final l10n = AppLocalizations.of(context);
        final scaffoldMessenger = ScaffoldMessenger.of(context);
        final homeProvider = context.read<HomeProvider>();

        scaffoldMessenger.showMaterialBanner(
          MaterialBanner(
            content: Text(
              l10n?.dailyReportAvailable ?? 'Your daily communication evaluation is ready',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: const Color(0xFF485DF4).withAlpha(200),
            leading: const Icon(Icons.assessment, color: Colors.white),
            actions: [
              TextButton(
                onPressed: () {
                  scaffoldMessenger.hideCurrentMaterialBanner();
                  SharedPreferencesUtil().lastDismissedDailyReport = report.reportDate;
                },
                child: Text(l10n?.dismiss ?? 'Dismiss', style: const TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () {
                  scaffoldMessenger.hideCurrentMaterialBanner();
                  SharedPreferencesUtil().lastDismissedDailyReport = report.reportDate;
                  // Navigate to Insights tab (nav index 4)
                  homeProvider.setIndex(4);
                },
                child: Text(l10n?.viewDailyReport ?? 'View Report', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('[HomePage] Error checking daily report: $e');
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
              key: _scaffoldKey,
              backgroundColor: Theme.of(context).colorScheme.primary,
              appBar: _buildAppBar(context),
              drawer: const AppNavigationDrawer(),
              body: DefaultTabController(
                length: 4,
                initialIndex: homeProvider.stackIndex,
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
                              index: context.watch<HomeProvider>().stackIndex,
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
                            return Stack(
                              children: [
                                // Bottom Navigation Bar - 5 positions with FAB center
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
                                        // Home tab (nav 0)
                                        _buildNavTab(
                                          icon: FontAwesomeIcons.house,
                                          isSelected: home.selectedIndex == 0,
                                          onTap: () {
                                            MixpanelManager().bottomNavigationTabClicked('Home');
                                            primaryFocus?.unfocus();
                                            if (home.selectedIndex == 0) {
                                              _scrollToTop(0);
                                              return;
                                            }
                                            home.setIndex(0);
                                          },
                                        ),
                                        // Conversations tab (nav 1)
                                        _buildNavTab(
                                          icon: FontAwesomeIcons.solidMessage,
                                          isSelected: home.selectedIndex == 1,
                                          onTap: () {
                                            MixpanelManager().bottomNavigationTabClicked('Conversations');
                                            primaryFocus?.unfocus();
                                            if (home.selectedIndex == 1) {
                                              _scrollToTop(1);
                                              return;
                                            }
                                            home.setIndex(1);
                                          },
                                        ),
                                        // Center space for FAB
                                        const SizedBox(width: 80),
                                        // Tasks tab (nav 3)
                                        _buildNavTab(
                                          icon: FontAwesomeIcons.listCheck,
                                          isSelected: home.selectedIndex == 3,
                                          onTap: () {
                                            MixpanelManager().bottomNavigationTabClicked('Tasks');
                                            primaryFocus?.unfocus();
                                            if (home.selectedIndex == 3) {
                                              _scrollToTop(3);
                                              return;
                                            }
                                            home.setIndex(3);
                                          },
                                        ),
                                        // Insights tab (nav 4)
                                        _buildNavTab(
                                          icon: FontAwesomeIcons.chartLine,
                                          isSelected: home.selectedIndex == 4,
                                          onTap: () {
                                            MixpanelManager().bottomNavigationTabClicked('Insights');
                                            primaryFocus?.unfocus();
                                            if (home.selectedIndex == 4) {
                                              _scrollToTop(4);
                                              return;
                                            }
                                            home.setIndex(4);
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // Central FAB Record Button
                                Positioned(
                                  left: MediaQuery.of(context).size.width / 2 - 32,
                                  bottom: 40,
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
                                          width: 64,
                                          height: 64,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: isRecording ? Colors.red : const Color(0xFF485DF4),
                                            border: Border.all(
                                              color: Colors.black,
                                              width: 4,
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
                                                  size: 22,
                                                ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
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

  Widget _buildNavTab({
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.mediumImpact();
          onTap();
        },
        child: SizedBox(
          height: 90,
          child: Center(
            child: Icon(
              icon,
              color: isSelected ? Colors.white : Colors.grey,
              size: 22,
            ),
          ),
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
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Hamburger menu to open drawer
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
                      FontAwesomeIcons.bars,
                      size: 16,
                      color: Colors.white70,
                    ),
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      MixpanelManager().drawerOpened();
                      _scaffoldKey.currentState?.openDrawer();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                const BatteryInfoWidget(),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Settings button
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
              // Chat Button
              GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  MixpanelManager().bottomNavigationTabClicked('Chat');
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
