import 'package:flutter/widgets.dart';
import 'package:omi/services/platform_logger.dart';

/// Global [NavigatorObserver] that emits `nav.page_view` events to
/// [PlatformLogger] when routes with a whitelisted `settings.name` are
/// pushed or replaced.
///
/// ## Why a whitelist, not auto-capture
/// [NavigatorObserver] receives the [Route] itself but cannot inspect the
/// widget inside a [MaterialPageRoute] without a [BuildContext]. The only
/// stable identifier available here is `route.settings.name`. Enforcing an
/// allowlist prevents leaking internal/debug routes and keeps analytics
/// readable.
///
/// ## How to get a route tracked
/// At the push site, set the name explicitly:
/// ```
/// Navigator.of(context).push(MaterialPageRoute(
///   settings: const RouteSettings(name: 'conversation_detail'),
///   builder: (_) => ConversationDetailPage(...),
/// ));
/// ```
/// If `settings.name` is null or not in [_allowedPages], the observer
/// stays silent.
///
/// ## Dialogs/bottom sheets
/// Only [PageRoute]s are considered — dialogs, popups and bottom sheets
/// are ignored (they're not "pages" from a product POV and would add noise).
class LoggerNavigatorObserver extends NavigatorObserver {
  /// Whitelist of route names treated as product-level pages.
  /// Kept as a set so lookup is O(1) and adding new pages is one line.
  static const Set<String> _allowedPages = {
    'conversation_detail',
    'conversation_capturing',
    'chat',
    'memories',
    'memories_review',
    'app_detail',
    'transcription_settings',
    'device_settings',
    'profile',
    'voice_profile',
    'payments',
    'referral',
    'find_device',
    'developer',
    'data_privacy',
    'sync_conversations',
    'about',
    'feedback',
    'settings',
    'speech_profile',
    'onboarding',
  };

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _maybeLog(route, source: 'push');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _maybeLog(newRoute, source: 'replace');
  }

  void _maybeLog(Route<dynamic> route, {required String source}) {
    if (route is! PageRoute) return;
    final name = route.settings.name;
    if (name == null) return;
    if (!_allowedPages.contains(name)) return;

    PlatformLogger.instance.logEvent('nav.page_view', data: {
      'page': name,
      'source': source,
    });
  }
}
