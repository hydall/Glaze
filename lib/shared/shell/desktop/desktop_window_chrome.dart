import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../widgets/glass_surface.dart';
import 'desktop_window_geometry.dart';

const Duration _kActiveFade = Duration(milliseconds: 150);

/// Border color of a window frame: accented while [active], a quiet outline
/// otherwise — still visible, so a window never melts into what is under it.
Color desktopWindowBorderColor(BuildContext context, {required bool active}) =>
    active
    ? context.cs.primary.withValues(alpha: 0.7)
    : context.cs.outline.withValues(alpha: 0.4);

/// The frame every window drawn over the desktop layout shares — floating
/// windows, sheet windows and the glossary — so they read as one kind of
/// thing: a glass panel with a [titleBar] on top of [child].
///
/// The [active] window (see `desktopSurfaceActiveProvider`) gets an accented
/// outline, a deeper shadow and full-strength title text; the others recede.
class DesktopWindowFrame extends StatelessWidget {
  final bool active;
  final bool maximized;
  final Widget titleBar;
  final Widget child;

  const DesktopWindowFrame({
    super.key,
    required this.active,
    this.maximized = false,
    required this.titleBar,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(maximized ? 0 : 16);
    return GlassSurface(
      borderRadius: radius,
      border: Border.all(
        color: desktopWindowBorderColor(context, active: active),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: active ? 0.5 : 0.3),
          blurRadius: active ? 40 : 24,
          spreadRadius: active ? 4 : 0,
        ),
      ],
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          children: [
            titleBar,
            Divider(height: 1, color: context.cs.outlineVariant),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// Title bar of a [DesktopWindowFrame]: back button, title, the hosted
/// screen's [actions], then whichever window buttons have a callback.
///
/// Wrap it in a [DesktopWindowMoveArea] to make it drag the window.
class DesktopWindowTitleBar extends StatelessWidget {
  final String title;
  final Widget? titleWidget;
  final List<Widget> actions;
  final bool active;
  final bool maximized;
  final VoidCallback? onBack;
  final VoidCallback? onDetach;
  final VoidCallback? onMinimize;
  final VoidCallback? onToggleMaximize;
  final VoidCallback? onClose;

  const DesktopWindowTitleBar({
    super.key,
    required this.title,
    this.titleWidget,
    this.actions = const [],
    required this.active,
    this.maximized = false,
    this.onBack,
    this.onDetach,
    this.onMinimize,
    this.onToggleMaximize,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final buttonColor = active
        ? context.cs.onSurfaceVariant
        : context.cs.onSurfaceVariant.withValues(alpha: 0.55);

    Widget windowButton(
      IconData icon,
      String tooltip,
      VoidCallback onPressed, {
      double size = 18,
    }) => IconButton(
      icon: Icon(icon, size: size),
      color: buttonColor,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );

    return SizedBox(
      height: kDesktopWindowTitleBarHeight,
      child: Row(
        children: [
          const SizedBox(width: 4),
          if (onBack != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              color: buttonColor,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child:
                titleWidget ??
                AnimatedDefaultTextStyle(
                  duration: _kActiveFade,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? context.cs.onSurface
                        : context.cs.onSurface.withValues(alpha: 0.55),
                  ),
                  child: Text(title, overflow: TextOverflow.ellipsis),
                ),
          ),
          ...actions,
          if (onDetach != null)
            windowButton(
              Icons.open_in_new_rounded,
              'desktop_window_detach'.tr(),
              onDetach!,
            ),
          if (onMinimize != null)
            windowButton(
              Icons.minimize_rounded,
              'desktop_window_minimize'.tr(),
              onMinimize!,
            ),
          if (onToggleMaximize != null)
            windowButton(
              maximized
                  ? Icons.fullscreen_exit_rounded
                  : Icons.crop_square_rounded,
              maximized
                  ? 'desktop_window_restore'.tr()
                  : 'desktop_window_maximize'.tr(),
              onToggleMaximize!,
            ),
          if (onClose != null)
            windowButton(
              Icons.close_rounded,
              MaterialLocalizations.of(context).closeButtonTooltip,
              onClose!,
              size: 20,
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
