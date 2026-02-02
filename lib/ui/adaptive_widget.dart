import 'package:flutter/widgets.dart';
import 'package:omi/utils/platform/platform_service.dart';

abstract class AdaptiveWidget extends StatelessWidget {
  const AdaptiveWidget({super.key});

  /// Build for desktop platforms (Windows, macOS).
  Widget buildDesktop(BuildContext context);

  /// Build for mobile platforms (Android, iOS).
  Widget buildMobile(BuildContext context);

  @override
  Widget build(BuildContext context) {
    if (PlatformService.isDesktop) {
      return buildDesktop(context);
    }
    return buildMobile(context);
  }
}
