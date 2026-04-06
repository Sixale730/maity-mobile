import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/http/api/messages.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/app.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/message.dart';
import 'package:omi/gen/assets.gen.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/chat/select_text_screen.dart';
import 'package:omi/pages/chat/widgets/ai_message.dart';
import 'package:omi/pages/chat/widgets/user_message.dart';
import 'package:omi/pages/chat/widgets/voice_recorder_widget.dart';
import 'package:omi/providers/connectivity_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:omi/widgets/extensions/string.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'widgets/message_action_menu.dart';

class ChatPage extends StatefulWidget {
  final bool isPivotBottom;

  const ChatPage({
    super.key,
    this.isPivotBottom = false,
  });

  @override
  State<ChatPage> createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  TextEditingController textController = TextEditingController();
  late ScrollController scrollController;
  late FocusNode textFieldFocusNode;

  bool isScrollingDown = false;

  bool _showVoiceRecorder = false;
  final bool _isInitialLoad = true;

  var prefs = SharedPreferencesUtil();
  late List<App> apps;

  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    apps = prefs.appsList;
    scrollController = ScrollController();
    textFieldFocusNode = FocusNode();
    textController.addListener(() {
      setState(() {});
    });

    scrollController.addListener(() {
      if (scrollController.position.userScrollDirection == ScrollDirection.reverse) {
        if (!isScrollingDown) {
          isScrollingDown = true;
          setState(() {});
          Future.delayed(const Duration(seconds: 5), () {
            if (isScrollingDown) {
              isScrollingDown = false;
              if (mounted) {
                setState(() {});
              }
            }
          });
        }
      }

      if (scrollController.position.userScrollDirection == ScrollDirection.forward) {
        if (isScrollingDown) {
          isScrollingDown = false;
          setState(() {});
        }
      }
    });
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      var provider = context.read<MessageProvider>();
      if (provider.messages.isEmpty) {
        provider.refreshMessages();
      }
      // Fetch enabled chat apps
      provider.fetchChatApps();
      scrollToBottom();
      // Auto-focus the text field only on initial load, not on app switches
      if (_isInitialLoad) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && !_showVoiceRecorder && _isInitialLoad) {
            textFieldFocusNode.requestFocus();
          }
        });
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    textController.dispose();
    scrollController.dispose();
    textFieldFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Consumer2<MessageProvider, ConnectivityProvider>(
      builder: (context, provider, connectivityProvider, child) {
        return Scaffold(
          key: scaffoldKey,
          backgroundColor: Theme.of(context).colorScheme.primary,
          appBar: _buildAppBar(context, provider),
          endDrawer: _buildSessionsDrawer(context, provider),
          body: GestureDetector(
            onTap: () {
              // Hide keyboard when tapping outside textfield
              FocusScope.of(context).unfocus();
            },
            child: Column(
              children: [
                // Messages area - takes up remaining space
                Expanded(
                  child: provider.isLoadingMessages && !provider.hasCachedMessages
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              provider.firstTimeLoadingText,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        )
                      : provider.isClearingChat
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  AppLocalizations.of(context)?.deletingMessages ?? "Deleting your messages from Maity's memory...",
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            )
                          : (provider.messages.isEmpty)
                              ? _buildEmptyStateWithQuickActions(context, connectivityProvider)
                              : ListView.builder(
                                  shrinkWrap: false,
                                  reverse: true,
                                  controller: scrollController,
                                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                                  itemCount: provider.messages.length,
                                  itemBuilder: (context, chatIndex) {
                                    final message = provider.messages[chatIndex];
                                    double topPadding = chatIndex == provider.messages.length - 1 ? 8 : 16;

                                    double bottomPadding = chatIndex == 0 ? 16 : 0;
                                    return GestureDetector(
                                      onLongPress: () {
                                        showModalBottomSheet(
                                          context: context,
                                          shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.vertical(
                                              top: Radius.circular(20),
                                            ),
                                          ),
                                          builder: (context) => MessageActionMenu(
                                            message: message.text.decodeString,
                                            onCopy: () async {
                                              MixpanelManager()
                                                  .track('Chat Message Copied', properties: {'message': message.text});
                                              await Clipboard.setData(ClipboardData(text: message.text.decodeString));
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      AppLocalizations.of(context)?.messageCopied ?? 'Message copied to clipboard.',
                                                      style: const TextStyle(
                                                        color: Color.fromARGB(255, 255, 255, 255),
                                                        fontSize: 12.0,
                                                      ),
                                                    ),
                                                    duration: const Duration(milliseconds: 2000),
                                                  ),
                                                );
                                                Navigator.pop(context);
                                              }
                                            },
                                            onSelectText: () {
                                              MixpanelManager().track('Chat Message Text Selected',
                                                  properties: {'message': message.text});
                                              routeToPage(context, SelectTextScreen(message: message));
                                            },
                                            onShare: () {
                                              MixpanelManager()
                                                  .track('Chat Message Shared', properties: {'message': message.text});
                                              Share.share(
                                                '${message.text.decodeString}\n\nResponse from Omi. Get yours at https://omi.me',
                                                subject: 'Chat with Omi',
                                              );
                                              Navigator.pop(context);
                                            },
                                            onThumbsUp: message.sender == MessageSender.ai && message.askForNps
                                                ? () {
                                                    provider.setMessageNps(message, 1);
                                                    Navigator.pop(context);
                                                    AppSnackbar.showSnackbar(AppLocalizations.of(context)?.thankYouFeedback ?? 'Thank you for your feedback!');
                                                  }
                                                : null,
                                            onThumbsDown: message.sender == MessageSender.ai && message.askForNps
                                                ? () {
                                                    provider.setMessageNps(message, 0);
                                                    Navigator.pop(context);
                                                    AppSnackbar.showSnackbar(AppLocalizations.of(context)?.thankYouFeedback ?? 'Thank you for your feedback!');
                                                  }
                                                : null,
                                            onReport: () {
                                              if (message.sender == MessageSender.human) {
                                                Navigator.pop(context);
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      AppLocalizations.of(context)?.cannotReportOwnMessage ?? 'You cannot report your own messages.',
                                                      style: const TextStyle(
                                                        color: Color.fromARGB(255, 255, 255, 255),
                                                        fontSize: 12.0,
                                                      ),
                                                    ),
                                                    duration: const Duration(milliseconds: 2000),
                                                  ),
                                                );
                                                return;
                                              }
                                              showDialog(
                                                context: context,
                                                builder: (context) {
                                                  return getDialog(
                                                    context,
                                                    () {
                                                      Navigator.of(context).pop();
                                                    },
                                                    () {
                                                      MixpanelManager().track('Chat Message Reported',
                                                          properties: {'message': message.text});
                                                      Navigator.of(context).pop();
                                                      Navigator.of(context).pop();
                                                      context.read<MessageProvider>().removeLocalMessage(message.id);
                                                      reportMessageServer(message.id);
                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        SnackBar(
                                                          content: Text(
                                                            AppLocalizations.of(context)?.messageReported ?? 'Message reported successfully.',
                                                            style: const TextStyle(
                                                              color: Color.fromARGB(255, 255, 255, 255),
                                                              fontSize: 12.0,
                                                            ),
                                                          ),
                                                          duration: const Duration(milliseconds: 2000),
                                                        ),
                                                      );
                                                    },
                                                    AppLocalizations.of(context)?.reportMessage ?? 'Report Message',
                                                    AppLocalizations.of(context)?.reportMessageConfirm ?? 'Are you sure you want to report this message?',
                                                  );
                                                },
                                              );
                                            },
                                          ),
                                        );
                                      },
                                      child: Padding(
                                        key: ValueKey(message.id),
                                        padding: EdgeInsets.only(bottom: bottomPadding, top: topPadding),
                                        child: message.sender == MessageSender.ai
                                            ? AIMessage(
                                                showTypingIndicator: provider.showTypingIndicator && chatIndex == 0,
                                                message: message,
                                                sendMessage: _sendMessageUtil,
                                                displayOptions: provider.messages.length <= 1 &&
                                                    provider.messageSenderApp(message.appId)?.isNotPersona() == true,
                                                appSender: provider.messageSenderApp(message.appId),
                                                updateConversation: (ServerConversation conversation) {
                                                  context.read<ConversationProvider>().updateConversation(conversation);
                                                },
                                                setMessageNps: (int value) {
                                                  provider.setMessageNps(message, value);
                                                },
                                              )
                                            : HumanMessage(message: message),
                                      ),
                                    );
                                  },
                                ),
                ),
                // Send message area - fixed at bottom
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  decoration: const BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(22),
                      topRight: Radius.circular(22),
                    ),
                  ),
                  child: Consumer<HomeProvider>(builder: (context, home, child) {
                    bool shouldShowSendButton(MessageProvider p) {
                      return !p.sendingMessage && !_showVoiceRecorder;
                    }

                    bool shouldShowVoiceRecorderButton() {
                      return !_showVoiceRecorder;
                    }

                    bool shouldShowMenuButton() {
                      return !_showVoiceRecorder;
                    }

                    return Column(
                      children: [
                        // Selected images display above the send bar
                        Consumer<MessageProvider>(builder: (context, provider, child) {
                          if (provider.selectedFiles.isNotEmpty) {
                            return Container(
                              margin: const EdgeInsets.only(top: 16, bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              height: 70,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: provider.selectedFiles.length,
                                itemBuilder: (ctx, idx) {
                                  return Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    width: 60,
                                    height: 60,
                                    decoration: BoxDecoration(
                                      color: Colors.grey[800],
                                      borderRadius: BorderRadius.circular(16),
                                      image: provider.selectedFileTypes[idx] == 'image'
                                          ? DecorationImage(
                                              image: FileImage(provider.selectedFiles[idx]),
                                              fit: BoxFit.cover,
                                            )
                                          : null,
                                    ),
                                    child: Stack(
                                      children: [
                                        // File icon for non-images
                                        if (provider.selectedFileTypes[idx] != 'image')
                                          const Center(
                                            child: Icon(
                                              Icons.insert_drive_file,
                                              color: Colors.white,
                                              size: 24,
                                            ),
                                          ),
                                        // Loading indicator
                                        if (provider.isFileUploading(provider.selectedFiles[idx].path))
                                          Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.5),
                                              borderRadius: BorderRadius.circular(16),
                                            ),
                                            child: const Center(
                                              child: SizedBox(
                                                width: 16,
                                                height: 16,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                                                ),
                                              ),
                                            ),
                                          ),
                                        // Close button
                                        Positioned(
                                          top: 4,
                                          right: 4,
                                          child: GestureDetector(
                                            onTap: () {
                                              provider.clearSelectedFile(idx);
                                            },
                                            child: Container(
                                              width: 16,
                                              height: 16,
                                              decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius: BorderRadius.circular(10),
                                              ),
                                              child: const Icon(
                                                FontAwesomeIcons.xmark,
                                                size: 10,
                                                color: Colors.black,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            );
                          } else {
                            return const SizedBox.shrink();
                          }
                        }),
                        // Send bar
                        Padding(
                          padding: EdgeInsets.only(
                            left: 8,
                            right: 8,
                            top: provider.selectedFiles.isNotEmpty ? 0 : 8,
                            bottom: widget.isPivotBottom ? 20 : (textFieldFocusNode.hasFocus ? 10 : 40),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2F),
                              borderRadius: BorderRadius.circular(32),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                // Plus button
                                if (shouldShowMenuButton())
                                  GestureDetector(
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      FocusScope.of(context).unfocus();
                                      if (provider.selectedFiles.length > 3) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(AppLocalizations.of(context)?.maxFilesLimit ?? 'You can only upload 4 files at a time'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                        return;
                                      }
                                      _showIOSStyleActionSheet(context);
                                    },
                                    child: Container(
                                      height: 44,
                                      width: 44,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF3C3C43),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: FaIcon(
                                          FontAwesomeIcons.plus,
                                          color: provider.selectedFiles.length > 3 ? Colors.grey : Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 12),
                                // Text field
                                Expanded(
                                  child: _showVoiceRecorder
                                      ? VoiceRecorderWidget(
                                          onTranscriptReady: (transcript) {
                                            setState(() {
                                              textController.text = transcript;
                                              _showVoiceRecorder = false;
                                              context.read<MessageProvider>().setNextMessageOriginIsVoice(true);
                                            });
                                          },
                                          onClose: () {
                                            setState(() {
                                              _showVoiceRecorder = false;
                                            });
                                          },
                                        )
                                      : TextField(
                                          enabled: true,
                                          controller: textController,
                                          focusNode: textFieldFocusNode,
                                          obscureText: false,
                                          textAlign: TextAlign.start,
                                          textAlignVertical: TextAlignVertical.center,
                                          decoration: InputDecoration(
                                            hintText: AppLocalizations.of(context)?.askAnything ?? 'Ask anything',
                                            hintStyle: const TextStyle(fontSize: 16.0, color: Colors.grey),
                                            focusedBorder: InputBorder.none,
                                            enabledBorder: InputBorder.none,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                                            isDense: true,
                                          ),
                                          minLines: 1,
                                          maxLines: 10,
                                          keyboardType: TextInputType.multiline,
                                          textCapitalization: TextCapitalization.sentences,
                                          style: const TextStyle(fontSize: 16.0, color: Colors.white, height: 1.4),
                                        ),
                                ),
                                // Microphone button
                                if (shouldShowVoiceRecorderButton() && textController.text.isEmpty)
                                  GestureDetector(
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      FocusScope.of(context).unfocus();
                                      setState(() {
                                        _showVoiceRecorder = true;
                                      });
                                    },
                                    child: Container(
                                      height: 44,
                                      width: 44,
                                      alignment: Alignment.center,
                                      child: const FaIcon(
                                        FontAwesomeIcons.microphone,
                                        color: Colors.grey,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                // Send button - only show when there's text
                                if (shouldShowSendButton(provider))
                                  ValueListenableBuilder<TextEditingValue>(
                                    valueListenable: textController,
                                    builder: (context, value, child) {
                                      bool hasText = value.text.trim().isNotEmpty;
                                      if (!hasText) return const SizedBox.shrink();

                                      bool canSend = hasText &&
                                          !provider.sendingMessage &&
                                          !provider.isUploadingFiles &&
                                          connectivityProvider.isConnected;

                                      return GestureDetector(
                                        onTap: canSend
                                            ? () {
                                                HapticFeedback.mediumImpact();
                                                String message = textController.text.trim();
                                                if (message.isEmpty) return;
                                                _sendMessageUtil(message);
                                              }
                                            : null,
                                        child: Container(
                                          height: 44,
                                          width: 44,
                                          decoration: const BoxDecoration(
                                            color: Colors.white,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Center(
                                            child: FaIcon(
                                              FontAwesomeIcons.arrowUp,
                                              color: Color(0xFF1f1f25),
                                              size: 18,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  _sendMessageUtil(String text) {
    // Remove focus from text field
    textFieldFocusNode.unfocus();

    var provider = context.read<MessageProvider>();
    provider.setSendingMessage(true);
    provider.addMessageLocally(text);
    textController.clear();

    // Scroll to align user's message to top of screen
    Future.delayed(const Duration(milliseconds: 100), () {
      scrollToBottom();
    });

    provider.sendMessageStreamToServer(text);
    provider.clearSelectedFiles();
    provider.setSendingMessage(false);
  }

  sendInitialAppMessage(App? app) async {
    context.read<MessageProvider>().setSendingMessage(true);
    scrollToBottom();
    ServerMessage message = await getInitialAppMessage(app?.id);
    if (mounted) {
      context.read<MessageProvider>().addMessage(message);
      scrollToBottom();
      context.read<MessageProvider>().setSendingMessage(false);
    }
  }

  void _moveListToBottom() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  scrollToBottom() => _moveListToBottom();

  void _showClearChatDialog() {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) {
        return getDialog(context, () {
          Navigator.of(context).pop();
        }, () {
          if (mounted) {
            context.read<MessageProvider>().clearChat();
            Navigator.of(context).pop();
          }
        }, AppLocalizations.of(context)?.clearChatQuestion ?? "Clear Chat?", AppLocalizations.of(context)?.clearChatConfirm ?? "Are you sure you want to clear the chat? This action cannot be undone.");
      },
    );
  }

  Widget _buildSessionsDrawer(BuildContext context, MessageProvider provider) {
    final sessions = provider.chatSessions;
    final activeId = provider.activeSessionId;

    return Drawer(
      backgroundColor: const Color(0xFF1A1A1F),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Historial de chats',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  IconButton(
                    icon: const Icon(FontAwesomeIcons.penToSquare, color: Color(0xFF485DF4), size: 18),
                    onPressed: () {
                      provider.createNewSession();
                      Navigator.of(context).pop();
                      scrollToBottom();
                    },
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF35343B), height: 1),
            // Sessions list
            Expanded(
              child: sessions.isEmpty
                  ? const Center(child: Text('Sin conversaciones', style: TextStyle(color: Colors.white38)))
                  : ListView.builder(
                      itemCount: sessions.length,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemBuilder: (context, index) {
                        final session = sessions[index];
                        final isActive = session['id'] == activeId;
                        return Dismissible(
                          key: Key(session['id']!),
                          direction: sessions.length > 1
                              ? DismissDirection.endToStart
                              : DismissDirection.none,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            color: Colors.red.withValues(alpha: 0.3),
                            child: const Icon(Icons.delete, color: Colors.red),
                          ),
                          onDismissed: (_) => provider.deleteSession(session['id']!),
                          child: ListTile(
                            dense: true,
                            selected: isActive,
                            selectedTileColor: const Color(0xFF485DF4).withValues(alpha: 0.15),
                            leading: Icon(
                              FontAwesomeIcons.solidMessage,
                              size: 16,
                              color: isActive ? const Color(0xFF485DF4) : Colors.white38,
                            ),
                            title: Text(
                              session['title'] ?? 'Chat',
                              style: TextStyle(
                                color: isActive ? Colors.white : Colors.white70,
                                fontSize: 14,
                                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: session['created_at'] != null
                                ? Text(
                                    _formatSessionDate(session['created_at']!),
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                                  )
                                : null,
                            onTap: () {
                              if (!isActive) {
                                provider.switchToSession(session['id']!);
                              }
                              Navigator.of(context).pop();
                              scrollToBottom();
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSessionDate(String isoDate) {
    try {
      final date = DateTime.parse(isoDate).toLocal();
      final now = DateTime.now();
      if (date.year == now.year && date.month == now.month && date.day == now.day) {
        return 'Hoy ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      }
      return '${date.day}/${date.month}/${date.year}';
    } catch (_) {
      return '';
    }
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, MessageProvider provider) {
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.surface,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: _buildAppSelection(context),
      centerTitle: true,
      actions: [
        // New chat button
        IconButton(
          icon: const Icon(FontAwesomeIcons.penToSquare, color: Colors.white, size: 18),
          tooltip: 'Nuevo chat',
          onPressed: () {
            HapticFeedback.mediumImpact();
            provider.createNewSession();
            scrollToBottom();
          },
        ),
        // Chat history drawer button
        IconButton(
          icon: const Icon(FontAwesomeIcons.clockRotateLeft, color: Colors.white, size: 18),
          tooltip: 'Historial de chats',
          onPressed: () {
            HapticFeedback.mediumImpact();
            scaffoldKey.currentState?.openEndDrawer();
          },
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          color: const Color(0xFF2A2A2F),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          offset: const Offset(0, 45),
          onSelected: (value) {
            if (value == 'clear_chat') {
              _showClearChatDialog();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'clear_chat',
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    AppLocalizations.of(context)?.clearChat ?? 'Clear Chat',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
      bottom: provider.isLoadingMessages
          ? PreferredSize(
              preferredSize: const Size.fromHeight(32),
              child: Container(
                width: double.infinity,
                height: 32,
                color: Colors.green,
                child: Center(
                  child: Text(
                    AppLocalizations.of(context)?.syncingMessages ?? 'Syncing messages with server...',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildAppSelection(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _getOmiAvatar(),
        const SizedBox(width: 8),
        const Text(
          "Maity",
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
      ],
    );
  }

  Widget _getOmiAvatar() {
    return Container(
      decoration: BoxDecoration(
        image: DecorationImage(
          image: AssetImage(Assets.images.background.path),
          fit: BoxFit.cover,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(16.0)),
      ),
      height: 24,
      width: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Image.asset(
            Assets.images.herologo.path,
            height: 16,
            width: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyStateWithQuickActions(BuildContext context, ConnectivityProvider connectivityProvider) {
    final l10n = AppLocalizations.of(context);

    if (!connectivityProvider.isConnected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 32.0),
          child: Text(
            l10n?.checkInternetConnection ?? 'Please check your internet connection and try again',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    // Quick actions data
    final quickActions = [
      {'icon': Icons.today, 'label': l10n?.todaySummary ?? 'Resumen de hoy', 'message': '¿Qué hice hoy?'},
      {'icon': Icons.check_circle_outline, 'label': l10n?.myTasks ?? 'Mis pendientes', 'message': '¿Cuáles son mis tareas pendientes?'},
      {'icon': Icons.bar_chart, 'label': l10n?.myStats ?? 'Mis estadísticas', 'message': '¿Cuáles son mis estadísticas del mes?'},
      {'icon': Icons.mic, 'label': l10n?.howICommunicate ?? 'Cómo me comunico', 'message': '¿Cómo es mi estilo de comunicación?'},
    ];

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
            // Welcome message
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2F),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  const FaIcon(
                    FontAwesomeIcons.handPeace,
                    size: 36,
                    color: Color(0xFFFFD93D),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n?.welcomeToMaity ?? '¡Hola! Soy Maity',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n?.maityWelcomeSubtitle ?? 'Tu asistente personal conectado a tu wearable. Pregúntame sobre tus conversaciones, tareas o estadísticas.',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Quick actions
            Text(
              l10n?.tryAsking ?? 'Prueba preguntar:',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: quickActions.map((action) {
                return _buildQuickActionChip(
                  icon: action['icon'] as IconData,
                  label: action['label'] as String,
                  onTap: () => _sendMessageUtil(action['message'] as String),
                );
              }).toList(),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActionChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF3C3C43),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey[700]!, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showIOSStyleActionSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return Container(
          margin: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Main options container
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E).withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Column(
                  children: [
                    _buildIOSActionItem(
                      title: AppLocalizations.of(context)?.takePhoto ?? "Take Photo",
                      icon: Icons.camera_alt,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(context);
                        if (mounted) {
                          context.read<MessageProvider>().captureImage();
                        }
                      },
                      isFirst: true,
                    ),
                    _buildDivider(),
                    _buildIOSActionItem(
                      title: AppLocalizations.of(context)?.photoLibrary ?? "Photo Library",
                      icon: Icons.photo_library,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(context);
                        if (mounted) {
                          context.read<MessageProvider>().selectImage();
                        }
                      },
                    ),
                    _buildDivider(),
                    _buildIOSActionItem(
                      title: AppLocalizations.of(context)?.chooseFile ?? "Choose File",
                      icon: Icons.folder,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(context);
                        if (mounted) {
                          context.read<MessageProvider>().selectFile();
                        }
                      },
                      isLast: true,
                    ),
                  ],
                ),
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 10),
            ],
          ),
        );
      },
    );
  }

  Widget _buildIOSActionItem({
    required String title,
    required VoidCallback onTap,
    IconData? icon,
    bool isFirst = false,
    bool isLast = false,
    bool isCancel = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.vertical(
          top: isFirst ? const Radius.circular(13) : Radius.zero,
          bottom: isLast ? const Radius.circular(13) : Radius.zero,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isCancel ? Colors.red : Colors.blue,
                    fontSize: 20,
                    fontWeight: isCancel ? FontWeight.w600 : FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              if (icon != null && !isCancel)
                Icon(
                  icon,
                  color: Colors.grey.shade600,
                  size: 24,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 0.5,
      color: Colors.grey.shade700,
      margin: const EdgeInsets.symmetric(horizontal: 20),
    );
  }
}
