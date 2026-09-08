import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/settings/app_settings_provider.dart';

final forceMobileLayoutProvider = Provider<bool>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return settings.value?.forceMobileLayout ?? false;
});

class DesktopScope extends InheritedWidget {
  final bool isDesktop;

  const DesktopScope({
    super.key,
    required this.isDesktop,
    required super.child,
  });

  static DesktopScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopScope>();

  static bool isDesktopOf(BuildContext context) =>
      maybeOf(context)?.isDesktop ?? false;

  @override
  bool updateShouldNotify(DesktopScope oldWidget) =>
      isDesktop != oldWidget.isDesktop;
}

bool isDesktopLayout(BuildContext context) =>
    DesktopScope.isDesktopOf(context);

class DesktopDetection extends StatelessWidget {
  final Widget child;

  const DesktopDetection({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // We can't read forceMobileLayout here without Consumer,
        // so this is used only where force check isn't needed.
        final isDesktop = width >= 768;
        return DesktopScope(isDesktop: isDesktop, child: child);
      },
    );
  }
}
