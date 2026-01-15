import 'package:flutter/foundation.dart';

Future<Map> getLatestFirmwareVersion({
  required String deviceModelNumber,
  required String firmwareRevision,
  required String hardwareRevision,
  required String manufacturerName,
}) async {
  // Disabled: api.omi.me is no longer used
  debugPrint('[API Disabled] getLatestFirmwareVersion skipped');
  return {};
}
