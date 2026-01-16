import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/analytics/intercom.dart';
import 'package:omi/utils/analytics/mixpanel.dart';
import 'package:omi/widgets/device_widget.dart';
import 'package:provider/provider.dart';

import '../conversations/sync_page.dart';
import 'firmware_update.dart';

class ConnectedDevice extends StatefulWidget {
  const ConnectedDevice({super.key});

  @override
  State<ConnectedDevice> createState() => _ConnectedDeviceState();
}

class _ConnectedDeviceState extends State<ConnectedDevice> {
  // TODO: thinh, use connection directly
  Future _bleDisconnectDevice(BtDevice btDevice) async {
    var connection = await ServiceManager.instance().device.ensureConnection(btDevice.id);
    if (connection == null) {
      return Future.value(null);
    }
    return await connection.disconnect();
  }

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<DeviceProvider>().getDeviceInfo();
    });
    super.initState();
  }

  IconData _getBatteryIcon(int batteryLevel) {
    if (batteryLevel > 75) {
      return FontAwesomeIcons.batteryFull;
    } else if (batteryLevel > 50) {
      return FontAwesomeIcons.batteryThreeQuarters;
    } else if (batteryLevel > 25) {
      return FontAwesomeIcons.batteryHalf;
    } else if (batteryLevel > 10) {
      return FontAwesomeIcons.batteryQuarter;
    } else {
      return FontAwesomeIcons.batteryEmpty;
    }
  }

  Widget _buildSectionRow(
    String title,
    String value, {
    bool hasArrow = false,
    bool isFirst = false,
    bool isLast = false,
    VoidCallback? onTap,
    bool isRedBackground = false,
    bool isDisabled = false,
  }) {
    final bool canCopy = value.isNotEmpty && !isDisabled;

    return GestureDetector(
      onTap: onTap ?? (canCopy ? () => _copyToClipboard(value) : null),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isRedBackground ? Colors.red.withValues(alpha: 0.1) : null,
          border: Border(
            bottom: isLast
                ? BorderSide.none
                : const BorderSide(
                    color: Color(0xFF35343B),
                    width: 0.5,
                  ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isRedBackground
                          ? Colors.red.shade300
                          : isDisabled
                              ? Colors.grey.shade500
                              : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  if (value.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        color: isRedBackground
                            ? Colors.red.shade200
                            : isDisabled
                                ? Colors.grey.shade500
                                : Colors.white54,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (hasArrow) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios,
                color: isRedBackground ? Colors.red.shade300 : Colors.white54,
                size: 16,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${AppLocalizations.of(context)?.copiedToClipboard ?? "Copied to clipboard"}: $text'),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<DeviceProvider, CaptureProvider>(builder: (context, provider, captureProvider, child) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.primary,
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.primary,
        ),
        body: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  const SizedBox(height: 0),
                  // Device Title and Status
                  Column(
                    children: [
                      Text(
                        provider.pairedDevice?.name ?? (AppLocalizations.of(context)?.unknownDevice ?? 'Unknown Device'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: provider.connectedDevice != null
                              ? Colors.green.withValues(alpha: 0.2)
                              : Colors.grey.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: provider.connectedDevice != null ? Colors.green : Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              provider.connectedDevice != null
                                  ? (AppLocalizations.of(context)?.connected ?? 'Connected')
                                  : (AppLocalizations.of(context)?.offline ?? 'Offline'),
                              style: TextStyle(
                                color: provider.connectedDevice != null ? Colors.green : Colors.grey,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  DeviceAnimationWidget(
                    deviceType: provider.connectedDevice?.type,
                    modelNumber: provider.connectedDevice?.modelNumber,
                    isConnected: provider.connectedDevice != null,
                    deviceName: provider.connectedDevice?.name ?? provider.pairedDevice?.name,
                    animatedBackground: provider.connectedDevice != null,
                  ),

                  const SizedBox(height: 8),
                  // Device Details Section
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Battery Level Section
                        if (provider.connectedDevice != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1F1F25),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                FaIcon(
                                  _getBatteryIcon(provider.batteryLevel),
                                  color: provider.batteryLevel > 75
                                      ? const Color.fromARGB(255, 0, 255, 8)
                                      : provider.batteryLevel > 20
                                          ? Colors.yellow.shade700
                                          : Colors.red,
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  AppLocalizations.of(context)?.batteryLevel ?? 'Battery Level',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${provider.batteryLevel}%',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (provider.connectedDevice != null) const SizedBox(height: 20),

                        // Controllable Items Section
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1F25),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              _buildSectionRow(
                                AppLocalizations.of(context)?.productUpdate ?? 'Product Update',
                                provider.connectedDevice == null
                                    ? (AppLocalizations.of(context)?.deviceMustBeConnected ?? 'Device must be connected')
                                    : '',
                                hasArrow: provider.connectedDevice != null,
                                isFirst: true,
                                isDisabled: provider.connectedDevice == null,
                                onTap: provider.connectedDevice != null
                                    ? () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (context) => FirmwareUpdate(device: provider.pairedDevice),
                                          ),
                                        );
                                      }
                                    : null,
                              ),
                              if (provider.isDeviceStorageSupport)
                                _buildSectionRow(
                                  AppLocalizations.of(context)?.sdCardSync ?? 'SD Card Sync',
                                  AppLocalizations.of(context)?.importAudioFiles ?? 'Import audio files from SD Card',
                                  hasArrow: true,
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => const SyncPage(),
                                      ),
                                    );
                                  },
                                ),
                              _buildSectionRow(
                                AppLocalizations.of(context)?.chargingIssues ?? 'Issues charging the device?',
                                AppLocalizations.of(context)?.tapToSeeGuide ?? 'Tap to see the guide',
                                hasArrow: true,
                                onTap: () async {
                                  await IntercomManager.instance
                                      .displayChargingArticle(provider.pairedDevice?.name ?? 'DevKit1');
                                },
                              ),
                              _buildSectionRow(
                                provider.connectedDevice == null
                                    ? (AppLocalizations.of(context)?.unpair ?? 'Unpair')
                                    : (AppLocalizations.of(context)?.disconnect ?? 'Disconnect'),
                                '',
                                hasArrow: true,
                                isLast: true,
                                isRedBackground: true,
                                onTap: () async {
                                  await SharedPreferencesUtil()
                                      .btDeviceSet(BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0));
                                  SharedPreferencesUtil().deviceName = '';
                                  if (provider.connectedDevice != null) {
                                    await _bleDisconnectDevice(provider.connectedDevice!);
                                  }
                                  if (context.mounted) {
                                    context.read<DeviceProvider>().setIsConnected(false);
                                    context.read<DeviceProvider>().setConnectedDevice(null);
                                    context.read<DeviceProvider>().updateConnectingStatus(false);
                                    Navigator.of(context).pop();
                                  }
                                  MixpanelManager().disconnectFriendClicked();
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Info Only Section
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1F25),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            children: [
                              _buildSectionRow(
                                AppLocalizations.of(context)?.productName ?? 'Product Name',
                                provider.pairedDevice?.name ?? (AppLocalizations.of(context)?.unknownDevice ?? 'Unknown Device'),
                                hasArrow: false,
                                isFirst: true,
                              ),
                              _buildSectionRow(
                                AppLocalizations.of(context)?.modelNumber ?? 'Model Number',
                                provider.pairedDevice?.modelNumber ?? (AppLocalizations.of(context)?.unknown ?? 'Unknown'),
                                hasArrow: false,
                              ),
                              _buildSectionRow(
                                AppLocalizations.of(context)?.manufacturerName ?? 'Manufacturer Name',
                                provider.pairedDevice?.manufacturerName ?? (AppLocalizations.of(context)?.unknown ?? 'Unknown'),
                                hasArrow: false,
                              ),
                              _buildSectionRow(
                                AppLocalizations.of(context)?.firmwareVersion ?? 'Firmware Version',
                                provider.pairedDevice?.firmwareRevision ?? (AppLocalizations.of(context)?.unknown ?? 'Unknown'),
                                hasArrow: false,
                              ),
                              _buildSectionRow(
                                AppLocalizations.of(context)?.deviceIdLabel ?? 'Device ID',
                                provider.pairedDevice?.id ?? (AppLocalizations.of(context)?.unknown ?? 'Unknown'),
                                hasArrow: false,
                              ),
                              _buildSectionRow(
                                AppLocalizations.of(context)?.serialNumber ?? 'Serial Number',
                                provider.pairedDevice?.id.replaceAll(':', '').replaceAll('-', '').toUpperCase() ??
                                    (AppLocalizations.of(context)?.unknown ?? 'Unknown'),
                                hasArrow: false,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Streaming Metrics Section - Bottom
                  if (provider.connectedDevice != null && captureProvider.havingRecordingDevice) ...[
                    const SizedBox(height: 32),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const FaIcon(
                            FontAwesomeIcons.bluetooth,
                            color: Colors.grey,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${captureProvider.bleReceiveRateKbps.toStringAsFixed(1)} kbps',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 24),
                          const FaIcon(
                            FontAwesomeIcons.signal,
                            color: Colors.grey,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${captureProvider.wsSendRateKbps.toStringAsFixed(1)} kbps',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 64), // Extra padding to ensure scrollable content
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}
