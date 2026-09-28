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

/// Shortest side (in logical pixels) at which a screen counts as a tablet.
///
/// A tablet's portrait width is often below [kDesktopWidthBreakpoint] even
/// though the screen has plenty of room for the three-column layout, which left
/// those tablets stuck on the phone layout when held upright. Flutter's own
/// window size classes put the tablet/medium cutoff at 600, and an 11" tablet
/// (e.g. 1920x1200 at 2x) reports exactly a 600dp shortest side in portrait, so
/// matching that value picks tablets up without touching phones, whose shortest
/// side is ~360-430.
const double kTabletShortestSideBreakpoint = 600;

/// Whether a viewport of [size] should use the desktop layout, ignoring the
/// "force mobile layout" setting.
///
/// True for any window wider than [kDesktopWidthBreakpoint], and for
/// tablet-sized screens in either orientation — their shortest side is at least
/// [kTabletShortestSideBreakpoint], so a portrait tablet qualifies too.
bool isDesktopViewportSize(Size size) =>
    size.width >= kDesktopWidthBreakpoint ||
    size.shortestSide >= kTabletShortestSideBreakpoint;

/// Whether the *window* is desktop-shaped, ignoring the "force mobile layout"
/// setting.
///
/// Use this for UI that must stay reachable regardless of that setting — the
/// settings group holding the switch itself, for one. Everything that should
/// follow the user's choice wants [isDesktopLayout].
bool isWideViewport(BuildContext context) =>
    isDesktopViewportSize(MediaQuery.sizeOf(context));

class DesktopDetection extends StatelessWidget {
  final Widget child;

  const DesktopDetection({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // We can't read forceMobileLayout here without Consumer,
        // so this is used only where force check isn't needed.
        final isDesktop = isDesktopViewportSize(
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        return DesktopScope(isDesktop: isDesktop, child: child);
      },
    );
  }
}
