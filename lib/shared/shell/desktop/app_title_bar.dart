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
import 'desktop_layout_provider.dart';
import 'title_bar_screen_header.dart';

/// Height of the app's own title bar.
const double kAppTitleBarHeight = 40;

/// Width of each of the minimize / maximize / close buttons.
const double _kCaptionButtonWidth = 46;

/// Draws the app's own title bar across the top of its OS window where the
/// system one is hidden (see [usesCustomAppTitleBar]), in the style of the
/// windows that float inside it.
///
/// In the desktop layout the bar also carries the header of the screen in the
/// middle column, Discord-style (see [TitleBarScreenHeader]); the mobile
/// layout keeps a plain bar with the app name.
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
    final desktopLayout =
        isDesktopViewportSize(MediaQuery.sizeOf(context)) &&
        !ref.watch(forceMobileLayoutProvider);
    // Dragging moves the OS window; a double-click maximizes it. Only empty
    // parts of the bar drag, so the header's buttons keep plain clicks.
    final logo = DragToMoveArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
        child: SvgPicture.string(
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
      ),
    );
    final appNameText = Text(
      'Glaze',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: foreground,
      ),
    );

    return Listener(
      onPointerDown: (_) => ref
          .read(desktopActiveSurfaceProvider.notifier)
          .activate(kDesktopMainSurface),
      // One edge under the whole bar; the columns below draw no top edge of
      // their own, so it is never doubled.
      child: GlassSurface(
        borderRadius: BorderRadius.zero,
        border: Border(bottom: BorderSide(color: context.cs.outlineVariant)),
        child: SizedBox(
          height: kAppTitleBarHeight,
          // A screen's header may bring a text field (the chat search), which
          // needs a Material above it; the bar sits outside the navigator's.
          child: Material(
            type: MaterialType.transparency,
            child: Row(
              children: [
                Expanded(
                  child: desktopLayout
                      ? TitleBarScreenHeader(
                          logo: logo,
                          fallback: appNameText,
                          // The caption buttons, so the title centres on the
                          // whole window.
                          endInset: 3 * _kCaptionButtonWidth,
                        )
                      : Row(
                          children: [
                            logo,
                            Expanded(
                              child: DragToMoveArea(
                                child: SizedBox.expand(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: appNameText,
                                  ),
                                ),
                              ),
                            ),
                          ],
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
        fixedSize: const WidgetStatePropertyAll(
          Size(_kCaptionButtonWidth, kAppTitleBarHeight),
        ),
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
