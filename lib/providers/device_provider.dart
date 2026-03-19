import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/http/api/device.dart';
import 'package:omi/main.dart';
import 'package:omi/pages/home/firmware_update.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/capture_log_service.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/utils/enums.dart';
import 'package:omi/utils/device.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/debouncer.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/widgets/confirmation_dialog.dart';

/// Localized notification messages for device connection/disconnection.
const _deviceNotificationMessages = {
  'en': {
    'connected_title': 'Maity Connected',
    'connected_body': 'Your device {deviceName} is now connected.',
    'disconnected_title': 'Maity Disconnected',
    'disconnected_body': 'Your device has disconnected. Attempting to reconnect...',
  },
  'es': {
    'connected_title': 'Maity Conectado',
    'connected_body': 'Tu dispositivo {deviceName} está conectado.',
    'disconnected_title': 'Maity Desconectado',
    'disconnected_body': 'Tu dispositivo se desconectó. Intentando reconectar...',
  }
};

class DeviceProvider extends ChangeNotifier implements IDeviceServiceSubsciption {
  CaptureProvider? captureProvider;

  bool isConnecting = false;
  bool isConnected = false;
  bool isDeviceStorageSupport = false;
  BtDevice? connectedDevice;
  BtDevice? pairedDevice;
  StreamSubscription<List<int>>? _bleBatteryLevelListener;
  int batteryLevel = -1;
  bool _hasLowBatteryAlerted = false;
  Timer? _reconnectionTimer;
  DateTime? _reconnectAt;

  // Exponential backoff for reconnection
  int _reconnectRetries = 0;
  static const int _initialBackoffMs = 2000; // 2 seconds
  static const double _backoffMultiplier = 1.5;
  static const int _maxBackoffMs = 60000; // 60 seconds
  static const int _maxReconnectRetries = 8;

  // Track stable connections to avoid resetting backoff on flapping
  DateTime? _lastStableConnectionTime;

  bool _havingNewFirmware = false;
  bool get havingNewFirmware => _havingNewFirmware && pairedDevice != null && isConnected;

  // Track firmware update state to prevent showing dialog during updates
  bool _isFirmwareUpdateInProgress = false;
  bool get isFirmwareUpdateInProgress => _isFirmwareUpdateInProgress;

  // Current and latest firmware versions for UI display
  String get currentFirmwareVersion => pairedDevice?.firmwareRevision ?? 'Unknown';
  String _latestFirmwareVersion = '';
  String get latestFirmwareVersion => _latestFirmwareVersion;

  Timer? _disconnectNotificationTimer;
  Timer? _bleDisconnectRecordingTimer;
  final Debouncer _disconnectDebouncer = Debouncer(delay: const Duration(milliseconds: 500));
  final Debouncer _connectDebouncer = Debouncer(delay: const Duration(milliseconds: 100));

  DeviceProvider() {
    ServiceManager.instance().device.subscribe(this, this);
  }

  void setProviders(CaptureProvider provider) {
    captureProvider = provider;
    notifyListeners();
  }

  void setConnectedDevice(BtDevice? device) async {
    connectedDevice = device;
    pairedDevice = device;
    await getDeviceInfo();
    Logger.debug('setConnectedDevice: $device');
    notifyListeners();
  }

  Future getDeviceInfo() async {
    if (connectedDevice != null) {
      if (pairedDevice?.firmwareRevision != null && pairedDevice?.firmwareRevision != 'Unknown') {
        return;
      }
      var connection = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
      pairedDevice = await connectedDevice?.getDeviceInfo(connection);
      SharedPreferencesUtil().btDevice = pairedDevice!;
    } else {
      if (SharedPreferencesUtil().btDevice.id.isEmpty) {
        pairedDevice = BtDevice.empty();
      } else {
        pairedDevice = SharedPreferencesUtil().btDevice;
      }
    }
    notifyListeners();
  }

  // TODO: thinh, use connection directly
  Future _bleDisconnectDevice(BtDevice btDevice) async {
    var connection = await ServiceManager.instance().device.ensureConnection(btDevice.id);
    if (connection == null) {
      return Future.value(null);
    }
    return await connection.disconnect();
  }

  Future<int> _retrieveBatteryLevel(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return -1;
    }
    return connection.retrieveBatteryLevel();
  }

  Future<StreamSubscription<List<int>>?> _getBleBatteryLevelListener(
    String deviceId, {
    void Function(int)? onBatteryLevelChange,
  }) async {
    {
      var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) {
        return Future.value(null);
      }
      return connection.getBleBatteryLevelListener(onBatteryLevelChange: onBatteryLevelChange);
    }
  }

  Future<List<int>> _getStorageList(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return [];
    }
    return connection.getStorageList();
  }

  Future<BtDevice?> _getConnectedDevice() async {
    var deviceId = SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) {
      return null;
    }
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    return connection?.device;
  }

  initiateBleBatteryListener() async {
    if (connectedDevice == null) {
      return;
    }
    _bleBatteryLevelListener?.cancel();
    _bleBatteryLevelListener = await _getBleBatteryLevelListener(
      connectedDevice!.id,
      onBatteryLevelChange: (int value) {
        // Filter out small fluctuations (noise from ADC readings)
        // Only update if change is >= 3% or if this is the first reading
        if ((batteryLevel - value).abs() < 3 && batteryLevel != -1) {
          return; // Ignore small fluctuations
        }
        batteryLevel = value;
        if (batteryLevel < 20 && !_hasLowBatteryAlerted) {
          _hasLowBatteryAlerted = true;
          NotificationService.instance.createNotification(
            title: "Low Battery Alert",
            body: "Your device is running low on battery. Time for a recharge! 🔋",
          );
        } else if (batteryLevel > 20) {
          _hasLowBatteryAlerted = true;
        }
        notifyListeners();
      },
    );
    notifyListeners();
  }

  Future periodicConnect(String printer, {bool boundDeviceOnly = false}) async {
    _reconnectionTimer?.cancel();

    Future<void> attemptReconnect() async {
      // Skip BLE reconnection during phone mic recording to avoid unnecessary overhead
      if (CaptureProvider.isRecordingWithPhoneMic) {
        debugPrint("Skipping BLE reconnection - phone mic recording active");
        return;
      }

      CaptureLogService.instance.log('ble', 'reconnect_attempt', severity: 'debug', details: {
        'retry': _reconnectRetries + 1,
        'max_retries': _maxReconnectRetries,
      });
      debugPrint("Reconnect attempt ${_reconnectRetries + 1}/$_maxReconnectRetries at ${DateTime.now()}");

      if (_reconnectAt != null && _reconnectAt!.isAfter(DateTime.now())) {
        // Schedule next attempt with backoff
        _scheduleNextReconnect(boundDeviceOnly);
        return;
      }

      if (boundDeviceOnly && SharedPreferencesUtil().btDevice.id.isEmpty) {
        debugPrint("No bound device, stopping reconnection");
        return;
      }

      Logger.debug("isConnected: $isConnected, isConnecting: $isConnecting, connectedDevice: $connectedDevice");

      if (!isConnected && connectedDevice == null) {
        if (isConnecting) {
          // Already connecting, schedule next check
          _scheduleNextReconnect(boundDeviceOnly);
          return;
        }

        await scanAndConnectToDevice();

        // Check if connection succeeded
        if (isConnected && connectedDevice != null) {
          debugPrint("Reconnection successful, resetting retries");
          _reconnectRetries = 0;
          return;
        }

        // Connection failed, increment retries and schedule next attempt
        _reconnectRetries++;
        if (_reconnectRetries >= _maxReconnectRetries) {
          CaptureLogService.instance.log('ble', 'reconnect_max_retries', severity: 'error', details: {
            'max_retries': _maxReconnectRetries,
          });
          debugPrint("Max reconnect retries reached ($_maxReconnectRetries)");
          _reconnectRetries = 0; // Reset for future attempts
          return;
        }

        _scheduleNextReconnect(boundDeviceOnly);
      } else {
        // Already connected
        _reconnectRetries = 0;
      }
    }

    attemptReconnect();
  }

  void _scheduleNextReconnect(bool boundDeviceOnly) {
    _reconnectionTimer?.cancel();

    // Calculate backoff delay with exponential increase
    int delayMs = (pow(_backoffMultiplier, _reconnectRetries) * _initialBackoffMs).toInt();
    delayMs = delayMs.clamp(0, _maxBackoffMs);

    debugPrint("Scheduling next reconnect in ${delayMs}ms (retry ${_reconnectRetries + 1}/$_maxReconnectRetries)");

    _reconnectionTimer = Timer(Duration(milliseconds: delayMs), () {
      periodicConnect('exponential backoff retry', boundDeviceOnly: boundDeviceOnly);
    });
  }

  Future<BtDevice?> _scanConnectDevice() async {
    var device = await _getConnectedDevice();
    if (device != null) {
      return device;
    }

    final pairedDeviceId = SharedPreferencesUtil().btDevice.id;
    if (pairedDeviceId.isNotEmpty) {
      try {
        Logger.debug('Attempting direct reconnection to paired device: $pairedDeviceId');
        await ServiceManager.instance().device.ensureConnection(pairedDeviceId, force: true);

        // Check if connection succeeded
        await Future.delayed(const Duration(seconds: 2));
        device = await _getConnectedDevice();
        if (device != null) {
          Logger.debug('Direct reconnection successful');
          return device;
        }
      } catch (e) {
        Logger.debug('Direct reconnection failed: $e');
      }
    }

    await ServiceManager.instance().device.discover(desirableDeviceId: pairedDeviceId);

    // Waiting for the device connected (if any)
    await Future.delayed(const Duration(seconds: 2));
    if (connectedDevice != null) {
      return connectedDevice;
    }
    return null;
  }

  Future scanAndConnectToDevice() async {
    updateConnectingStatus(true);
    if (isConnected) {
      if (connectedDevice == null) {
        connectedDevice = await _getConnectedDevice();
        SharedPreferencesUtil().deviceName = connectedDevice!.name;
        MixpanelManager().deviceConnected();
      }

      setIsConnected(true);
      updateConnectingStatus(false);
      notifyListeners();
      return;
    }

    // else
    var device = await _scanConnectDevice();
    Logger.debug('inside scanAndConnectToDevice $device in device_provider');
    if (device != null) {
      var cDevice = await _getConnectedDevice();
      if (cDevice != null) {
        setConnectedDevice(cDevice);
        setisDeviceStorageSupport();
        SharedPreferencesUtil().deviceName = cDevice.name;
        MixpanelManager().deviceConnected();
        setIsConnected(true);
      }
      Logger.debug('device is not null $cDevice');
    }
    updateConnectingStatus(false);

    notifyListeners();
  }

  void updateConnectingStatus(bool value) {
    isConnecting = value;
    notifyListeners();
  }

  void setIsConnected(bool value) {
    isConnected = value;
    if (isConnected) {
      _reconnectionTimer?.cancel();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _bleBatteryLevelListener?.cancel();
    _reconnectionTimer?.cancel();
    _bleDisconnectRecordingTimer?.cancel();
    _disconnectDebouncer.cancel();
    _connectDebouncer.cancel();
    ServiceManager.instance().device.unsubscribe(this);
    super.dispose();
  }

  void onDeviceDisconnected() async {
    Logger.debug('onDisconnected inside: $connectedDevice');
    CaptureLogService.instance.log('ble', 'device_disconnected', severity: 'warning', details: {
      'device_id': connectedDevice?.id,
      'device_name': connectedDevice?.name,
    });
    _havingNewFirmware = false;
    setConnectedDevice(null);
    setisDeviceStorageSupport();
    setIsConnected(false);
    updateConnectingStatus(false);

    // Only reset reconnection retries if the connection was stable (>5s)
    // This prevents backoff reset during rapid connect/disconnect flapping
    final wasStable = _lastStableConnectionTime != null &&
        DateTime.now().difference(_lastStableConnectionTime!).inSeconds > 5;
    if (wasStable) {
      _reconnectRetries = 0;
    }
    _lastStableConnectionTime = null;

    captureProvider?.updateRecordingDevice(null);

    // Debounce: wait 3s before stopping recording (allow BLE flicker reconnection)
    _bleDisconnectRecordingTimer?.cancel();
    if (captureProvider?.recordingState == RecordingState.deviceRecord) {
      _bleDisconnectRecordingTimer = Timer(const Duration(seconds: 3), () {
        // If still disconnected after 3s, stop recording
        if (connectedDevice == null) {
          debugPrint('[DeviceProvider] BLE still disconnected after 3s, stopping recording');
          captureProvider?.stopStreamDeviceRecording();
        }
      });
    }

    // Wals
    ServiceManager.instance().wal.getSyncs().sdcard.setDevice(null);

    PlatformManager.instance.crashReporter.logInfo('Maity Device Disconnected');
    _disconnectNotificationTimer?.cancel();
    _disconnectNotificationTimer = Timer(const Duration(seconds: 5), () {
      final lang = SharedPreferencesUtil().appLanguage;
      final messages = _deviceNotificationMessages[lang] ?? _deviceNotificationMessages['en']!;
      NotificationService.instance.createNotification(
        title: messages['disconnected_title']!,
        body: messages['disconnected_body']!,
        notificationId: 1,
      );
    });
    MixpanelManager().deviceDisconnected();

    // Retired 1s to prevent the race condition made by standby power of ble device
    Future.delayed(const Duration(seconds: 1), () {
      periodicConnect('coming from onDisconnect');
    });
  }

  Future<(String, bool, String)> shouldUpdateFirmware() async {
    if (pairedDevice == null || connectedDevice == null) {
      return ('No paired device is connected', false, '');
    }

    var device = pairedDevice!;
    var latestFirmwareDetails = await getLatestFirmwareVersion(
      deviceModelNumber: device.modelNumber,
      firmwareRevision: device.firmwareRevision,
      hardwareRevision: device.hardwareRevision,
      manufacturerName: device.manufacturerName,
    );

    return await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: device.firmwareRevision, latestFirmwareDetails: latestFirmwareDetails);
  }

  void _onDeviceConnected(BtDevice device) async {
    Logger.debug('_onConnected inside: $connectedDevice');
    CaptureLogService.instance.log('ble', 'device_connected', details: {
      'device_id': device.id,
      'device_name': device.name,
      'device_type': device.type.name,
    });
    _lastStableConnectionTime = DateTime.now();
    _bleDisconnectRecordingTimer?.cancel();
    _disconnectNotificationTimer?.cancel();
    NotificationService.instance.clearNotification(1);

    // Connection notification (localized)
    final lang = SharedPreferencesUtil().appLanguage;
    final messages = _deviceNotificationMessages[lang] ?? _deviceNotificationMessages['en']!;
    NotificationService.instance.createNotification(
      title: messages['connected_title']!,
      body: messages['connected_body']!.replaceAll('{deviceName}', device.name),
      notificationId: 2,
    );

    // Analytics for device connection
    MixpanelManager().deviceConnected();

    setConnectedDevice(device);

    if (captureProvider != null) {
      captureProvider?.updateRecordingDevice(device);
    }

    setisDeviceStorageSupport();
    setIsConnected(true);

    // Read initial battery level
    int currentLevel = await _retrieveBatteryLevel(device.id);
    if (currentLevel != -1) {
      batteryLevel = currentLevel;
    }

    // Then set up listener for battery changes
    await initiateBleBatteryListener();
    if (batteryLevel != -1 && batteryLevel < 20) {
      _hasLowBatteryAlerted = false;
    }
    updateConnectingStatus(false);
    await captureProvider?.streamDeviceRecording(device: device);

    await getDeviceInfo();
    SharedPreferencesUtil().deviceName = device.name;

    // Wals
    ServiceManager.instance().wal.getSyncs().sdcard.setDevice(device);

    notifyListeners();

    // Check firmware updates
    _checkFirmwareUpdates();
  }

  void _handleDeviceConnected(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return;
    }
    _onDeviceConnected(connection.device);
  }

  void _checkFirmwareUpdates() async {
    if (_isFirmwareUpdateInProgress) {
      return;
    }

    await checkFirmwareUpdates();

    // Show firmware update dialog if needed
    if (_havingNewFirmware) {
      // Use a small delay to ensure the UI is ready
      Future.delayed(const Duration(milliseconds: 500), () {
        final context = MyApp.navigatorKey.currentContext;
        if (context != null) {
          showFirmwareUpdateDialog(context);
        }
      });
    }
  }

  Future checkFirmwareUpdates() async {
    int retryCount = 0;
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 3);

    while (retryCount < maxRetries) {
      try {
        var (message, hasUpdate, version) = await shouldUpdateFirmware();
        _havingNewFirmware = hasUpdate;
        _latestFirmwareVersion = version.isNotEmpty ? version : message;
        notifyListeners();
        return hasUpdate; // Return whether there's an update
      } catch (e) {
        retryCount++;
        Logger.debug('Error checking firmware update (attempt $retryCount): $e');

        if (retryCount == maxRetries) {
          Logger.debug('Max retries reached, giving up');
          _havingNewFirmware = false;
          notifyListeners();
          break;
        }

        await Future.delayed(retryDelay);
      }
    }
    return;
  }

  void showFirmwareUpdateDialog(BuildContext context) {
    if (!_havingNewFirmware || !SharedPreferencesUtil().showFirmwareUpdateDialog || _isFirmwareUpdateInProgress) {
      return;
    }

    showDialog(
      context: context,
      builder: (context) => ConfirmationDialog(
        title: 'Firmware Update Available',
        description:
            'A new firmware update ($_latestFirmwareVersion) is available for your Omi device. Would you like to update now?',
        confirmText: 'Update',
        cancelText: 'Later',
        onConfirm: () {
          Navigator.of(context).pop();
          setFirmwareUpdateInProgress(true);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => FirmwareUpdate(device: pairedDevice),
            ),
          );
        },
        onCancel: () {
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Future setisDeviceStorageSupport() async {
    if (connectedDevice == null) {
      isDeviceStorageSupport = false;
    } else {
      var storageFiles = await _getStorageList(connectedDevice!.id);
      isDeviceStorageSupport = storageFiles.isNotEmpty;
    }
    notifyListeners();
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    Logger.debug("provider > device connection state changed...$deviceId...$state...${connectedDevice?.id}");
    switch (state) {
      case DeviceConnectionState.connected:
        _disconnectDebouncer.cancel();
        _connectDebouncer.run(() => _handleDeviceConnected(deviceId));
        break;
      case DeviceConnectionState.disconnected:
        _connectDebouncer.cancel();
        // Check if this is the paired device or currently connected device
        // Coz connectedDevice and pairedDevice are the same but connectedDevice becomes null after disconnect
        if (deviceId == connectedDevice?.id || deviceId == pairedDevice?.id) {
          _disconnectDebouncer.run(onDeviceDisconnected);
        }
        break;
      default:
        Logger.debug("Device connection state is not supported $state");
    }
  }

  @override
  void onDevices(List<BtDevice> devices) async {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  prepareDFU() {
    if (connectedDevice == null) {
      return;
    }
    _bleDisconnectDevice(connectedDevice!);
    _reconnectAt = DateTime.now().add(const Duration(seconds: 30));
  }

  // Reset firmware update state when update completes or fails
  void resetFirmwareUpdateState() {
    _isFirmwareUpdateInProgress = false;
    notifyListeners();
  }

  // Set firmware update state when starting an update
  void setFirmwareUpdateInProgress(bool inProgress) {
    _isFirmwareUpdateInProgress = inProgress;
    notifyListeners();
  }
}
