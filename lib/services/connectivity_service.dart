import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;

  ConnectivityService._internal();

  final InternetConnection _internetConnection = InternetConnection.createInstance(
    useDefaultOptions: false,
    checkInterval: const Duration(seconds: 10),
    customCheckOptions: [
      InternetCheckOption(
        uri: Uri.parse('https://one.one.one.one'),
        timeout: const Duration(seconds: 3),
      ),
      InternetCheckOption(
        uri: Uri.parse('https://maity-mobile.vercel.app/health'),
        timeout: const Duration(seconds: 3),
        responseStatusFn: (response) {
          return response.statusCode < 500;
        },
      ),
    ],
  );
  InternetConnection get internetConnection => _internetConnection;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription? _connectivitySubscription;
  StreamSubscription? _internetSubscription;

  final _connectionChangeController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionChange => _connectionChangeController.stream;

  bool _isConnected = false; // Start pessimistic until first check confirms
  bool get isConnected => _isConnected;
  bool _isInitialized = false;

  final Completer<void> _initCompleter = Completer<void>();

  /// Future that completes when the first connectivity check is done.
  /// Consumers should await this before relying on [isConnected].
  Future<void> get initialized => _initCompleter.future;

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      final connectivityResult = await _connectivity.checkConnectivity();
      if (connectivityResult.contains(ConnectivityResult.none)) {
        _isConnected = false;
      } else {
        _isConnected = await _internetConnection.hasInternetAccess;
        _internetSubscription = _internetConnection.onStatusChange.listen(_handleInternetStatusChange);
      }

      _connectivitySubscription = _connectivity.onConnectivityChanged.listen(_handleConnectivityChange);
    } catch (e) {
      print('[ConnectivityService] init() error: $e');
      _isConnected = false;
    } finally {
      _isInitialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      // Emit initial state so listeners know the resolved connectivity
      _connectionChangeController.add(_isConnected);
    }
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _internetSubscription?.cancel();
    _connectionChangeController.close();
  }

  void _handleConnectivityChange(List<ConnectivityResult> result) {
    if (result.contains(ConnectivityResult.mobile) ||
        result.contains(ConnectivityResult.wifi) ||
        result.contains(ConnectivityResult.ethernet)) {
      _internetConnection.hasInternetAccess.then(_updateConnectionState);
      _internetSubscription ??= _internetConnection.onStatusChange.listen(_handleInternetStatusChange);
      return;
    }

    // No internet
    _updateConnectionState(false);
    _internetSubscription?.cancel();
    _internetSubscription = null;
  }

  void _handleInternetStatusChange(InternetStatus status) {
    _updateConnectionState(status == InternetStatus.connected);
  }

  void _updateConnectionState(bool newIsConnected) {
    if (_isConnected != newIsConnected) {
      _isConnected = newIsConnected;
      _connectionChangeController.add(_isConnected);
    }
  }
}
