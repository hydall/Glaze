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

bool isDesktopLayout(BuildContext context) => DesktopScope.isDesktopOf(context);

/// Width at which the app switches to its desktop layout.
const double kDesktopWidthBreakpoint = 768;

/// Whether the *window* is wide, ignoring the "force mobile layout" setting.
///
/// Use this for UI that must stay reachable regardless of that setting — the
/// settings group holding the switch itself, for one. Everything that should
/// follow the user's choice wants [isDesktopLayout].
bool isWideViewport(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kDesktopWidthBreakpoint;

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
        final isDesktop = width >= kDesktopWidthBreakpoint;
        return DesktopScope(isDesktop: isDesktop, child: child);
      },
    );
  }
}
