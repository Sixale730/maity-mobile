import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/vad/vad_config.dart';
import 'package:omi/services/vad/vad_metrics.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';

/// Dialog for configuring VAD (Voice Activity Detection) settings.
class VadSettingsDialog {
  static Future<void> show(BuildContext context, {VadMetrics? currentMetrics}) async {
    final prefs = SharedPreferencesUtil();
    VadConfig config = prefs.vadConfig;
    final l10n = AppLocalizations.of(context);

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const FaIcon(FontAwesomeIcons.waveSquare, color: Colors.white, size: 20),
                  const SizedBox(width: 12),
                  Text(
                    l10n?.vadSettings ?? 'Voice Activity Detection',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Description
                      Text(
                        l10n?.vadDescription ??
                            'Filter silence to reduce transcription costs. Only send audio when speech is detected.',
                        style: const TextStyle(
                          color: Color(0xFF8E8E93),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Enable/Disable toggle
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n?.vadEnabled ?? 'Enable VAD',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    l10n?.vadEnabledDesc ?? 'Filter silence before transcription',
                                    style: const TextStyle(
                                      color: Color(0xFF8E8E93),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: config.enabled,
                              onChanged: (value) {
                                setState(() {
                                  config = config.copyWith(enabled: value);
                                });
                              },
                              activeTrackColor: const Color(0xFF22C55E),
                            ),
                          ],
                        ),
                      ),

                      // Advanced settings (only show when enabled)
                      if (config.enabled) ...[
                        const SizedBox(height: 16),

                        // Speech Threshold slider
                        _buildSliderSetting(
                          title: l10n?.vadThreshold ?? 'Speech Threshold',
                          description: l10n?.vadThresholdDesc ?? 'Higher = more strict detection',
                          value: config.speechThreshold,
                          min: 0.1,
                          max: 0.9,
                          divisions: 8,
                          valueLabel: config.speechThreshold.toStringAsFixed(1),
                          onChanged: (value) {
                            setState(() {
                              config = config.copyWith(speechThreshold: value);
                            });
                          },
                        ),
                        const SizedBox(height: 12),

                        // Pre-roll buffer
                        _buildOptionSetting(
                          title: l10n?.vadPreRoll ?? 'Pre-roll Buffer',
                          description: l10n?.vadPreRollDesc ?? 'Buffer before speech detection',
                          options: [
                            {'label': '150ms', 'value': 150},
                            {'label': '300ms', 'value': 300},
                            {'label': '500ms', 'value': 500},
                          ],
                          currentValue: config.preRollMs,
                          onChanged: (value) {
                            setState(() {
                              config = config.copyWith(preRollMs: value);
                            });
                          },
                        ),
                        const SizedBox(height: 12),

                        // Hang-over time
                        _buildOptionSetting(
                          title: l10n?.vadHangOver ?? 'Hang-over Time',
                          description: l10n?.vadHangOverDesc ?? 'Continue after speech ends',
                          options: [
                            {'label': '300ms', 'value': 300},
                            {'label': '500ms', 'value': 500},
                            {'label': '800ms', 'value': 800},
                          ],
                          currentValue: config.hangOverMs,
                          onChanged: (value) {
                            setState(() {
                              config = config.copyWith(hangOverMs: value);
                            });
                          },
                        ),
                      ],

                      // Current session metrics (if available)
                      if (currentMetrics != null && currentMetrics.totalAudioFrames > 0) ...[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E3A2F),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const FaIcon(FontAwesomeIcons.chartLine, color: Color(0xFF22C55E), size: 14),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n?.vadSessionStats ?? 'Session Stats',
                                    style: const TextStyle(
                                      color: Color(0xFF22C55E),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _buildMetricRow(
                                l10n?.vadTotalAudio ?? 'Total Audio',
                                '${currentMetrics.totalSeconds.toStringAsFixed(1)}s',
                              ),
                              _buildMetricRow(
                                l10n?.vadSentAudio ?? 'Sent',
                                '${currentMetrics.sentSeconds.toStringAsFixed(1)}s',
                              ),
                              _buildMetricRow(
                                l10n?.vadFilteredAudio ?? 'Filtered',
                                '${currentMetrics.filteredSeconds.toStringAsFixed(1)}s',
                              ),
                              const Divider(color: Color(0xFF3C3C43), height: 16),
                              _buildMetricRow(
                                l10n?.vadEstimatedSavings ?? 'Est. Savings',
                                '${currentMetrics.savingsPercent.toStringAsFixed(1)}%',
                                highlight: true,
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Info banner
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF3C3C43)),
                        ),
                        child: Row(
                          children: [
                            const FaIcon(FontAwesomeIcons.circleInfo, color: Color(0xFF8E8E93), size: 14),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                l10n?.vadInfoBanner ??
                                    'VAD works best with Custom STT (Deepgram). Typical savings: 40-70%.',
                                style: const TextStyle(
                                  color: Color(0xFF8E8E93),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: Text(
                    l10n?.cancel ?? 'Cancel',
                    style: const TextStyle(color: Color(0xFF8E8E93)),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    // Capture navigator before async gap
                    final navigator = Navigator.of(context);
                    final message = config.enabled
                        ? (l10n?.vadEnabledMessage ?? 'VAD enabled. Silence will be filtered.')
                        : (l10n?.vadDisabledMessage ?? 'VAD disabled. All audio will be sent.');

                    await prefs.saveVadConfig(config);
                    navigator.pop();

                    // Show confirmation
                    AppSnackbar.showSnackbar(message);
                  },
                  child: Text(
                    l10n?.save ?? 'Save',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Widget _buildSliderSetting({
    required String title,
    required String description,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF3C3C43),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  valueLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: const TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: const Color(0xFF22C55E),
              inactiveTrackColor: const Color(0xFF3C3C43),
              thumbColor: Colors.white,
              overlayColor: const Color(0xFF22C55E).withValues(alpha: 0.2),
              trackHeight: 4,
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildOptionSetting({
    required String title,
    required String description,
    required List<Map<String, dynamic>> options,
    required int currentValue,
    required ValueChanged<int> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: const TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: options.map((option) {
              final isSelected = currentValue == option['value'];
              return Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(option['value'] as int),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF22C55E) : const Color(0xFF3C3C43),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        option['label'] as String,
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white,
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  static Widget _buildMetricRow(String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: highlight ? const Color(0xFF22C55E) : const Color(0xFFAEAEB2),
              fontSize: 13,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: highlight ? const Color(0xFF22C55E) : Colors.white,
              fontSize: 13,
              fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
