import 'package:flutter/material.dart';

Future<void> saveFcmTokenServer({required String token, required String timeZone}) async {
  // Disabled: api.omi.me doesn't accept our Firebase tokens
  // FCM notifications would need our own backend implementation
  debugPrint('[FCM] Token save skipped - using local Firebase project');
}
