import 'dart:async';

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/platform/platform_service.dart';
// Intercom disabled - causes build issues
// import 'package:intercom_flutter/intercom_flutter.dart';

// Stub class to replace Intercom functionality
class IntercomManager {
  static final IntercomManager _instance = IntercomManager._internal();
  static IntercomManager get instance => _instance;
  static final SharedPreferencesUtil _preferences = SharedPreferencesUtil();

  IntercomManager._internal();

  // Intercom get intercom => Intercom.instance;
  bool get _isIntercomEnabled => false; // Always disabled

  factory IntercomManager() {
    return _instance;
  }

  Future<void> initIntercom() async {
    // Intercom disabled - no-op
    return;
  }

  Future displayChargingArticle(String device) async {
    // Intercom disabled - no-op
    return;
  }

  Future loginIdentifiedUser(String uid) async {
    // Intercom disabled - no-op
    return;
  }

  Future loginUnidentifiedUser() async {
    // Intercom disabled - no-op
    return;
  }

  Future displayEarnMoneyArticle() async {
    // Intercom disabled - no-op
    return;
  }

  Future displayFirmwareUpdateArticle() async {
    // Intercom disabled - no-op
    return;
  }

  Future logEvent(String eventName, {Map<String, dynamic>? metaData}) async {
    // Intercom disabled - no-op
    return;
  }

  Future updateCustomAttributes(Map<String, dynamic> attributes) async {
    // Intercom disabled - no-op
    return;
  }

  Future updateUser(String? email, String? name, String? uid) async {
    // Intercom disabled - no-op
    return;
  }

  Future<void> setUserAttributes() async {
    // Intercom disabled - no-op
    return;
  }

  Future<void> sendTokenToIntercom(String token) async {
    // Intercom disabled - no-op
    return;
  }
}
