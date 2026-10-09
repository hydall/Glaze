import 'package:flutter/foundation.dart';
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

/// App-wide [DesktopScope], provided above the router by the app's builder.
///
/// The shell provides its own scope around its columns, but everything on the
/// root navigator sits above it — dialogs, sheet windows, pages pushed with
/// `rootNavigator: true`, onboarding. Without this they read "not desktop", so
/// a sheet opened from one of them slid up as a bottom sheet instead of opening
/// as a window. Uses the shell's own rule (see `DesktopShell.build`), so both
/// scopes always agree.
class AppDesktopScope extends ConsumerWidget {
  final Widget child;

  const AppDesktopScope({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DesktopScope(
      isDesktop:
          isDesktopViewportSize(MediaQuery.sizeOf(context)) &&
          !ref.watch(forceMobileLayoutProvider),
      child: child,
    );
  }
}

/// Width at which the app switches to its desktop layout.
const double kDesktopWidthBreakpoint = 768;

/// Shortest side (in logical pixels) at which a touch screen counts as a
/// tablet.
///
/// Used in two places: to decide whether the app may rotate out of portrait at
/// startup (see `main.dart`), and to keep a portrait tablet on the phone layout
/// even when its width clears [kDesktopWidthBreakpoint]. Flutter's window size
/// classes put the tablet/medium cutoff at 600, and an 11" tablet (e.g.
/// 1920x1200 at 2x, a 600dp portrait width) reports exactly that shortest side,
/// while phones stay around 360-430.
const double kTabletShortestSideBreakpoint = 600;

/// Whether the current platform is a touch phone/tablet OS rather than a
/// desktop one. Only these get the portrait-tablet exception below.
bool get _isTouchPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Whether a viewport of [size] should use the desktop layout, ignoring the
/// "force mobile layout" setting.
///
/// True for any window wider than [kDesktopWidthBreakpoint] — except a
/// tablet-sized touch screen held in portrait: the three-column layout is a
/// landscape arrangement, so those stay on the phone layout when upright and
/// switch to desktop once rotated. Desktop windows are exempt, so a tall window
/// on a portrait monitor is still a desktop.
bool isDesktopViewportSize(Size size) {
  if (size.width < kDesktopWidthBreakpoint) return false;
  final portraitTablet =
      _isTouchPlatform &&
      size.shortestSide >= kTabletShortestSideBreakpoint &&
      size.height > size.width;
  return !portraitTablet;
}

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
