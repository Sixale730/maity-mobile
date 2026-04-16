import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:omi/utils/bluetooth/bluetooth_adapter.dart';

import 'device_transport.dart';

class BleTransport extends DeviceTransport {
  final BluetoothDevice _bleDevice;
  final StreamController<DeviceTransportState> _connectionStateController;
  final Map<String, StreamController<List<int>>> _streamControllers = {};
  final Map<String, StreamSubscription> _characteristicSubscriptions = {};

  List<BluetoothService> _services = [];
  DeviceTransportState _state = DeviceTransportState.disconnected;
  StreamSubscription<BluetoothConnectionState>? _bleConnectionSubscription;

  BleTransport(this._bleDevice) : _connectionStateController = StreamController<DeviceTransportState>.broadcast() {
    _bleConnectionSubscription = _bleDevice.connectionState.listen((state) {
      switch (state) {
        case BluetoothConnectionState.disconnected:
          // Clear stale stream resources on unexpected disconnect
          if (_state == DeviceTransportState.connected || _state == DeviceTransportState.connecting) {
            debugPrint('[BleTransport] Unexpected disconnect while ${_state.name}, clearing stale resources');
            for (final sub in _characteristicSubscriptions.values) {
              sub.cancel();
            }
            _characteristicSubscriptions.clear();
            for (final controller in _streamControllers.values) {
              controller.close();
            }
            _streamControllers.clear();
          }
          _updateState(DeviceTransportState.disconnected);
          break;
        case BluetoothConnectionState.connected:
          _updateState(DeviceTransportState.connected);
          break;
        // connecting/disconnecting are deprecated in flutter_blue_plus 1.33+
        // (iOS/Android never emit them), but must be listed for exhaustiveness.
        default:
          break;
      }
    });
  }

  @override
  String get deviceId => _bleDevice.remoteId.str;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _connectionStateController.stream;

  void _updateState(DeviceTransportState newState) {
    if (_state != newState) {
      _state = newState;
      _connectionStateController.add(_state);
    }
  }

  @override
  Future<void> connect() async {
    if (_state == DeviceTransportState.connected || _state == DeviceTransportState.connecting) {
      debugPrint('[BleTransport] Already ${_state.name}, skipping connect');
      return;
    }

    _updateState(DeviceTransportState.connecting);

    try {
      // Wait for Bluetooth adapter to be ready with timeout
      try {
        await BluetoothAdapter.adapterState
            .where((val) => val == BluetoothAdapterStateHelper.on)
            .first
            .timeout(const Duration(seconds: 10));
      } on TimeoutException {
        debugPrint('BLE Transport: Bluetooth adapter timeout - adapter may be off');
        _updateState(DeviceTransportState.disconnected);
        throw Exception('Bluetooth adapter not ready');
      }

      // Connect with autoConnect: true — chipset reconnects automatically when
      // device returns to range (same pattern as BT headphones).
      // 30s timeout prevents hanging on first connection attempts.
      try {
        await _bleDevice.connect(autoConnect: true, mtu: null)
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        debugPrint('[BleTransport] Connection timeout after 30s');
        _updateState(DeviceTransportState.disconnected);
        throw Exception('BLE connection timeout');
      }
      await _bleDevice.connectionState.where((val) => val == BluetoothConnectionState.connected).first;

      // Request larger MTU for better performance on Android
      if (Platform.isAndroid && _bleDevice.mtuNow < 512) {
        await _bleDevice.requestMtu(512);
      }

      // Discover services
      _services = await _bleDevice.discoverServices();

      _updateState(DeviceTransportState.connected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) {
      return;
    }

    _updateState(DeviceTransportState.disconnecting);

    try {
      for (final subscription in _characteristicSubscriptions.values) {
        await subscription.cancel();
      }
      _characteristicSubscriptions.clear();

      for (final controller in _streamControllers.values) {
        await controller.close();
      }
      _streamControllers.clear();

      await _bleDevice.disconnect();

      // Cancel BLE connection state listener to prevent ghost events after disconnect
      await _bleConnectionSubscription?.cancel();
      _bleConnectionSubscription = null;

      _updateState(DeviceTransportState.disconnected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<bool> isConnected() async {
    return _bleDevice.isConnected;
  }

  @override
  Future<bool> ping() async {
    try {
      await _bleDevice.readRssi(timeout: 10);
      return true;
    } catch (e) {
      debugPrint('BLE Transport ping failed: $e');
      return false;
    }
  }

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid:$characteristicUuid';

    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = StreamController<List<int>>.broadcast();
      _setupCharacteristicListener(serviceUuid, characteristicUuid, key);
    }

    return _streamControllers[key]!.stream;
  }

  Future<void> _setupCharacteristicListener(String serviceUuid, String characteristicUuid, String key) async {
    try {
      final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
      if (characteristic == null) {
        debugPrint('BLE Transport: Characteristic not found: $serviceUuid:$characteristicUuid');
        return;
      }

      await characteristic.setNotifyValue(true);

      final subscription = characteristic.lastValueStream.listen(
        (value) {
          if (_streamControllers[key] != null && !_streamControllers[key]!.isClosed) {
            _streamControllers[key]!.add(value);
          }
        },
        onError: (error) {
          debugPrint('BLE Transport characteristic stream error: $error');
        },
      );

      _characteristicSubscriptions[key] = subscription;
      _bleDevice.cancelWhenDisconnected(subscription);
    } catch (e) {
      debugPrint('BLE Transport: Failed to setup characteristic listener: $e');
    }
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) {
      return [];
    }

    try {
      return await characteristic.read();
    } catch (e) {
      debugPrint('BLE Transport: Failed to read characteristic: $e');
      return [];
    }
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) {
      throw Exception('Characteristic not found: $serviceUuid:$characteristicUuid');
    }

    try {
      // Use allowLongWrite when data exceeds the current MTU size
      // MTU includes 3 bytes overhead for ATT protocol, so usable payload is MTU - 3
      final useAllowLongWrite = data.length > (_bleDevice.mtuNow - 3);
      await characteristic.write(data, allowLongWrite: useAllowLongWrite);
    } catch (e) {
      debugPrint('BLE Transport: Failed to write characteristic: $e');
      rethrow;
    }
  }

  Future<BluetoothCharacteristic?> _getCharacteristic(String serviceUuid, String characteristicUuid) async {
    final service = _services.firstWhereOrNull(
      (service) => service.uuid.str128.toLowerCase() == serviceUuid.toLowerCase(),
    );

    if (service == null) {
      return null;
    }

    return service.characteristics.firstWhereOrNull(
      (characteristic) => characteristic.uuid.str128.toLowerCase() == characteristicUuid.toLowerCase(),
    );
  }

  @override
  Future<void> dispose() async {
    await _bleConnectionSubscription?.cancel();

    for (final subscription in _characteristicSubscriptions.values) {
      await subscription.cancel();
    }
    _characteristicSubscriptions.clear();

    for (final controller in _streamControllers.values) {
      await controller.close();
    }
    _streamControllers.clear();

    await _connectionStateController.close();
  }
}
