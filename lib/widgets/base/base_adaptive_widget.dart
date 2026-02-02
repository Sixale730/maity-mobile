import 'package:flutter/material.dart';
import 'package:omi/utils/platform/platform_service.dart';

/// Base class for widgets that adapt their layout based on platform
abstract class BaseAdaptiveWidget extends StatelessWidget {
  const BaseAdaptiveWidget({super.key});

  /// Check if current platform is mobile (Android, iOS)
  bool isMobile(BuildContext context) => PlatformService.isMobile;

  /// Check if current platform is desktop (Windows, macOS)
  bool isDesktop(BuildContext context) => PlatformService.isDesktop;

  /// Subclasses must implement mobile layout
  Widget buildMobile(BuildContext context);

  /// Subclasses must implement desktop layout
  Widget buildDesktop(BuildContext context);

  @override
  Widget build(BuildContext context) {
    return isMobile(context) ? buildMobile(context) : buildDesktop(context);
  }
}
