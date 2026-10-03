import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/platform/desktop_window.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/glaze_logo.dart';
import 'app_window_state_provider.dart';
import 'desktop_active_surface_provider.dart';

/// Height of the app's own title bar.
const double kAppTitleBarHeight = 40;

/// Draws the app's own title bar across the top of its OS window where the
/// system one is hidden (see [usesCustomAppTitleBar]), in the style of the
/// windows that float inside it.
///
/// The bar is laid over the app rather than stacked above it, and the app gets
/// its height as top padding — the way a phone's status bar is handled. Every
/// layout already keeps clear of that inset, the app background still runs
/// under the glass bar, and screen coordinates stay the window's own, so a
/// popup anchored at the pointer lands where it should.
class AppWindowFrame extends StatelessWidget {
  final Widget child;

  const AppWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!usesCustomAppTitleBar) return child;
    final media = MediaQuery.of(context);
    EdgeInsets inset(EdgeInsets padding) =>
        padding.copyWith(top: padding.top + kAppTitleBarHeight);
    return Stack(
      fit: StackFit.expand,
      children: [
        MediaQuery(
          data: media.copyWith(
            padding: inset(media.padding),
            viewPadding: inset(media.viewPadding),
          ),
          child: child,
        ),
        const Positioned(top: 0, left: 0, right: 0, child: _AppTitleBar()),
      ],
    );
  }
}

class _AppTitleBar extends ConsumerWidget {
  const _AppTitleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maximized = ref.watch(
      appWindowStateProvider.select((s) => s.maximized),
    );
    // Active like any other window: while the user works in the main window,
    // and dimmed while a floating window or another app has their attention.
    final active = ref.watch(desktopSurfaceActiveProvider(kDesktopMainSurface));
    final foreground = active
        ? context.cs.onSurface
        : context.cs.onSurface.withValues(alpha: 0.55);

    return Listener(
      onPointerDown: (_) => ref
          .read(desktopActiveSurfaceProvider.notifier)
          .activate(kDesktopMainSurface),
      // No bottom edge of its own: the columns below draw theirs, and a second
      // line right under the bar doubled it.
      child: GlassSurface(
        borderRadius: BorderRadius.zero,
        child: SizedBox(
          height: kAppTitleBarHeight,
          child: Row(
            children: [
              // Dragging moves the OS window; a double-click maximizes it.
              Expanded(
                child: DragToMoveArea(
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      SvgPicture.string(
                        glazeFilledLogoSvg,
                        width: 16,
                        height: 16,
                        colorFilter: ColorFilter.mode(
                          active
                              ? context.cs.primary
                              : context.cs.primary.withValues(alpha: 0.55),
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Glaze',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _CaptionButton(
                icon: Icons.minimize_rounded,
                tooltip: 'desktop_window_minimize',
                color: foreground,
                onPressed: windowManager.minimize,
              ),
              _CaptionButton(
                icon: maximized
                    ? Icons.fullscreen_exit_rounded
                    : Icons.crop_square_rounded,
                tooltip: maximized
                    ? 'desktop_window_restore'
                    : 'desktop_window_maximize',
                color: foreground,
                onPressed: maximized
                    ? windowManager.unmaximize
                    : windowManager.maximize,
              ),
              _CaptionButton(
                icon: Icons.close_rounded,
                color: foreground,
                onPressed: windowManager.close,
                isClose: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the minimize / maximize / close buttons: full bar height and square
/// edged like the native ones, close turning red under the pointer.
class _CaptionButton extends StatelessWidget {
  final IconData icon;

  /// Translation key of the tooltip; the close button uses the platform's.
  final String? tooltip;
  final Color color;
  final Future<void> Function() onPressed;
  final bool isClose;

  const _CaptionButton({
    required this.icon,
    this.tooltip,
    required this.color,
    required this.onPressed,
    this.isClose = false,
  });

  static const Color _closeHover = Color(0xFFC42B1C);

  @override
  Widget build(BuildContext context) {
    final hoverColor = isClose
        ? _closeHover
        : context.cs.onSurface.withValues(alpha: 0.08);
    return IconButton(
      icon: Icon(icon, size: isClose ? 18 : 16),
      // Opens in the app's [RootOverlay]: the bar is above the navigator.
      tooltip: isClose
          ? MaterialLocalizations.of(context).closeButtonTooltip
          : tooltip?.tr(),
      onPressed: onPressed,
      style: ButtonStyle(
        fixedSize: const WidgetStatePropertyAll(Size(46, kAppTitleBarHeight)),
        minimumSize: const WidgetStatePropertyAll(Size.zero),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) ? hoverColor : null,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => isClose && states.contains(WidgetState.hovered)
              ? Colors.white
              : color,
        ),
      ),
    );
  }
}
