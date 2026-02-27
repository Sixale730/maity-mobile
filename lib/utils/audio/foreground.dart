import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/platform/platform_service.dart';

/// Localized notification messages for foreground service.
/// The TaskHandler runs in a separate isolate and cannot access AppLocalizations,
/// so we use hardcoded maps for localization.
const _notificationMessages = {
  'en': {
    'waiting': 'No device connected. Tap to record.',
    'device_connected': 'Device connected - Ready to record',
    'phone_mic': 'Phone mic active - Ready to record',
    'recording': 'Recording...',
    'processing': 'Processing audio...',
    'ready': 'Transcription service ready',
  },
  'es': {
    'waiting': 'Sin dispositivo conectado. Toca para grabar.',
    'device_connected': 'Dispositivo conectado - Listo para grabar',
    'phone_mic': 'Micrófono activo - Listo para grabar',
    'recording': 'Grabando...',
    'processing': 'Procesando audio...',
    'ready': 'Servicio de transcripción listo',
  }
};

/// Localized button texts for notification action buttons.
const _buttonTexts = {
  'en': {
    'connect_device': 'Connect',
    'use_phone_mic': 'Use Mic',
  },
  'es': {
    'connect_device': 'Conectar',
    'use_phone_mic': 'Usar Mic',
  }
};

@pragma('vm:entry-point')
void _startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_ForegroundFirstTaskHandler());
}

class _ForegroundFirstTaskHandler extends TaskHandler {
  DateTime? _locationUpdatedAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter taskStarter) async {
    debugPrint("Starting foreground task");
    _locationInBackground();
  }

  Future _locationInBackground() async {
    if (await Geolocator.isLocationServiceEnabled()) {
      if (await Geolocator.checkPermission() == LocationPermission.always) {
        var locationData = await Geolocator.getCurrentPosition();
        if (_locationUpdatedAt == null ||
            _locationUpdatedAt!.isBefore(DateTime.now().subtract(const Duration(minutes: 5)))) {
          Object loc = {
            "latitude": locationData.latitude,
            "longitude": locationData.longitude,
            'altitude': locationData.altitude,
            'accuracy': locationData.accuracy,
            'time': locationData.timestamp.toUtc().toIso8601String(),
          };
          FlutterForegroundTask.sendDataToMain(loc);
          _locationUpdatedAt = DateTime.now();
        }
      } else {
        Object loc = {'error': 'Always location permission is not granted'};
        FlutterForegroundTask.sendDataToMain(loc);
      }
    } else {
      Object loc = {'error': 'Location service is not enabled'};
      FlutterForegroundTask.sendDataToMain(loc);
    }
  }

  @override
  void onReceiveData(Object data) async {
    debugPrint('onReceiveData: $data');

    // Handle notification state updates
    if (data is String) {
      try {
        final Map<String, dynamic> parsed = jsonDecode(data);
        if (parsed['type'] == 'notification') {
          final String state = parsed['state'] ?? 'ready';
          final String lang = parsed['lang'] ?? 'en';
          await _updateNotification(state, lang);
          return;
        }
      } catch (e) {
        debugPrint('Failed to parse notification data: $e');
      }
    }

    await _locationInBackground();
  }

  Future<void> _updateNotification(String state, String lang) async {
    // Get localized messages, fallback to English if language not found
    final messages = _notificationMessages[lang] ?? _notificationMessages['en']!;
    final notificationText = messages[state] ?? messages['ready']!;

    debugPrint('Updating notification: state=$state, lang=$lang, text=$notificationText');

    // Only show action buttons when in 'waiting' state (no device connected, not recording)
    // Use empty list to clear buttons for other states (null doesn't remove existing buttons)
    List<NotificationButton> buttons = [];
    if (state == 'waiting') {
      final btnTexts = _buttonTexts[lang] ?? _buttonTexts['en']!;
      buttons = [
        NotificationButton(id: 'connect_device', text: btnTexts['connect_device']!),
        NotificationButton(id: 'use_phone_mic', text: btnTexts['use_phone_mic']!),
      ];
    }

    await FlutterForegroundTask.updateService(
      notificationTitle: 'Maity',
      notificationText: notificationText,
      notificationButtons: buttons,
    );
  }

  @override
  void onNotificationButtonPressed(String id) {
    debugPrint('Notification button pressed: $id');
    // Send the action to the main app so it can navigate appropriately
    FlutterForegroundTask.sendDataToMain({'action': id});
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    debugPrint("Foreground repeat event triggered");
    await _locationInBackground();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint("Destroying foreground task");
    FlutterForegroundTask.stopService();
  }
}

class ForegroundUtil {
  static bool _isInitialized = false;
  static bool _isStarting = false;

  /// Gets the initial notification text based on the current language setting.
  static String _getInitialNotificationText() {
    final lang = SharedPreferencesUtil().appLanguage;
    final messages = _notificationMessages[lang] ?? _notificationMessages['en']!;
    return messages['waiting']!;
  }

  /// Request only notification permission (Android 13+).
  /// Does NOT request battery optimization exemption.
  static Future<void> requestNotificationPermission() async {
    final NotificationPermission notificationPermissionStatus =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermissionStatus != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  static Future<void> requestPermissions() async {
    // Android 13+, you need to allow notification permission to display foreground service notification.
    //
    // iOS: If you need notification, ask for permission.
    final NotificationPermission notificationPermissionStatus =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermissionStatus != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      // if (!await FlutterForegroundTask.canDrawOverlays) {
      //   await FlutterForegroundTask.openSystemAlertWindowSettings();
      // }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  Future<bool> get isIgnoringBatteryOptimizations async => await FlutterForegroundTask.isIgnoringBatteryOptimizations;

  static Future<void> initializeForegroundService() async {
    if (PlatformService.isDesktop) return;

    if (_isInitialized) {
      debugPrint('ForegroundService already initialized, skipping');
      return;
    }

    if (await FlutterForegroundTask.isRunningService) {
      _isInitialized = true;
      return;
    }

    debugPrint('initializeForegroundService');

    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'foreground_service',
          channelName: 'Foreground Service Notification',
          channelDescription: 'Transcription service is running in the background.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.HIGH,
          // iconData: const NotificationIconData(
          //   resType: ResourceType.mipmap,
          //   resPrefix: ResourcePrefix.ic,
          //   name: 'launcher',
          // ),
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          // Warn: 5m, for location tracking. If we want to support other services, we use the differenct interval,
          // such as 1m + self-validation in each service.
          eventAction: ForegroundTaskEventAction.repeat(60 * 1000 * 5),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      _isInitialized = true;
      debugPrint('ForegroundService initialized successfully');
    } catch (e) {
      debugPrint('ForegroundService initialization failed: $e');
      _isInitialized = false;
    }
  }

  static Future<ServiceRequestResult> startForegroundTask() async {
    if (PlatformService.isDesktop) return const ServiceRequestSuccess();

    if (_isStarting) {
      debugPrint('ForegroundTask already starting, skipping');
      return const ServiceRequestSuccess();
    }

    _isStarting = true;
    debugPrint('startForegroundTask');

    try {
      ServiceRequestResult result;
      if (await FlutterForegroundTask.isRunningService) {
        result = await FlutterForegroundTask.restartService();
      } else {
        result = await FlutterForegroundTask.startService(
          notificationTitle: 'Maity',
          notificationText: _getInitialNotificationText(),
          callback: _startForegroundCallback,
        );
      }
      debugPrint('ForegroundTask started successfully');
      return result;
    } catch (e) {
      debugPrint('ForegroundTask start failed: $e');
      return ServiceRequestFailure(error: e.toString());
    } finally {
      _isStarting = false;
    }
  }

  static Future<void> stopForegroundTask() async {
    if (PlatformService.isDesktop) return;
    debugPrint('stopForegroundTask');

    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        _isInitialized = false;
      }
    } catch (e) {
      debugPrint('ForegroundTask stop failed: $e');
    }
  }
}
