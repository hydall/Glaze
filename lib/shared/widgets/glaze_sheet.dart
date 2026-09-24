import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/desktop/desktop_layout_provider.dart';
import '../shell/shell_header_provider.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';

/// Width cap of a desktop sheet window. Matches the modal-sheet cap the theme
/// applies on mobile (`kSheetMaxWidthConstraints`), kept here as a literal to
/// avoid a theme import.
const double kGlazeSheetWindowMaxWidth = 640;

/// Fraction of the window height a desktop sheet window may occupy.
const double _kGlazeSheetWindowHeightFactor = 0.85;

/// Marks content hosted inside a [showGlazeSheet] desktop window.
///
/// Unlike a modal bottom sheet, a window has rounded corners on every side and
/// no drag handle, and it fills a bounded slot rather than the whole screen.
/// Widgets that care ([SheetView], [GlazeBottomSheetFrame]) read this to drop
/// their sheet-specific chrome.
class GlazeSheetWindowScope extends InheritedWidget {
  /// Whether the window sizes itself to its content (up to the height cap)
  /// instead of taking a fixed height.
  final bool contentSized;

  const GlazeSheetWindowScope({
    super.key,
    required this.contentSized,
    required super.child,
  });

  static GlazeSheetWindowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlazeSheetWindowScope>();

  static bool of(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(GlazeSheetWindowScope oldWidget) =>
      oldWidget.contentSized != contentSized;
}

/// Presents [builder] as a modal sheet.
///
/// On phones (and whenever the desktop layout is off) this is exactly
/// [showModalBottomSheet]: it forwards every argument, so existing call sites
/// keep their behaviour. On desktop it opens the same content as a centered,
/// floating window with a dimmed backdrop instead of a full-width band sliding
/// in from the bottom.
///
/// The window's height is fixed unless [windowContentSized] is set, in which
/// case it hugs its content up to [kGlazeSheetWindowMaxWidth]'s height cap. A
/// window with [windowChrome] draws a title bar (fed by the hosted screen's
/// shell-header claim) plus a close button; without it the content supplies its
/// own header, as [GlazeBottomSheet] does.
Future<T?> showGlazeSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useSafeArea = false,
  Color? backgroundColor,
  Color? barrierColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  bool windowContentSized = false,
  bool windowChrome = true,
  String? windowTitle,
  List<Widget>? windowActions,
}) {
  if (isDesktopLayout(context)) {
    return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
      _GlazeSheetWindowRoute<T>(
        builder: builder,
        dismissible: isDismissible,
        barrier: barrierColor ?? Colors.black54,
        label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        contentSized: windowContentSized,
        chrome: windowChrome,
        windowTitle: windowTitle,
        windowActions: windowActions,
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    barrierColor: barrierColor,
    shape: shape,
    constraints: constraints,
  );
}

class _GlazeSheetWindowRoute<T> extends PopupRoute<T> {
  final WidgetBuilder builder;
  final bool dismissible;
  final Color barrier;
  final String label;
  final bool contentSized;
  final bool chrome;
  final String? windowTitle;
  final List<Widget>? windowActions;

  _GlazeSheetWindowRoute({
    required this.builder,
    required this.dismissible,
    required this.barrier,
    required this.label,
    required this.contentSized,
    required this.chrome,
    this.windowTitle,
    this.windowActions,
  });

  @override
  Color? get barrierColor => barrier;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String get barrierLabel => label;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return GlazeSheetWindow(
      contentSized: contentSized,
      chrome: chrome,
      fallbackTitle: windowTitle,
      fallbackActions: windowActions,
      child: builder(context),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// The window chrome around a desktop sheet's content: centers it, caps its
/// size and — when [chrome] is set — draws a title bar and publishes it as a
/// [DetachedShellHost] so a hosted [SheetView] hands its title there.
class GlazeSheetWindow extends StatelessWidget {
  final bool contentSized;
  final bool chrome;
  final String? fallbackTitle;
  final List<Widget>? fallbackActions;
  final Widget child;

  const GlazeSheetWindow({
    super.key,
    required this.contentSized,
    required this.chrome,
    this.fallbackTitle,
    this.fallbackActions,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width * 0.92 < kGlazeSheetWindowMaxWidth
        ? size.width * 0.92
        : kGlazeSheetWindowMaxWidth;
    final maxHeight = size.height * _kGlazeSheetWindowHeightFactor;

    final Widget framed = chrome
        ? _WindowFrame(
            fallbackTitle: fallbackTitle,
            fallbackActions: fallbackActions,
            child: child,
          )
        : _SheetPanel(child: child);

    final Widget sized = contentSized
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: framed,
          )
        : SizedBox(height: maxHeight, child: framed);

    return GlazeSheetWindowScope(
      contentSized: contentSized,
      // The route lives on the root navigator, above the shell's [DesktopScope].
      // Re-provide it so a sheet opened from inside this window (a nested
      // GlazeBottomSheet, say) still opens as a window instead of a bottom
      // sheet.
      child: DesktopScope(
        isDesktop: true,
        child: Center(child: SizedBox(width: width, child: sized)),
      ),
    );
  }
}

/// Shadowed, rounded wrapper for a chrome-less window whose content paints its
/// own surface (a [GlazeBottomSheet]).
class _SheetPanel extends StatelessWidget {
  final Widget child;

  const _SheetPanel({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 40,
            spreadRadius: 4,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          child: child,
        ),
      ),
    );
  }
}

class _WindowFrame extends ConsumerWidget {
  final String? fallbackTitle;
  final List<Widget>? fallbackActions;
  final Widget child;

  const _WindowFrame({
    this.fallbackTitle,
    this.fallbackActions,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(
      shellHeaderProvider.select(
        (e) => resolveShellHeader(e, kDetachedChromeBranch),
      ),
    );
    final title = entry?.config.title ?? fallbackTitle ?? '';
    final actions = <Widget>[
      ...?entry?.config.actions,
      ...?fallbackActions,
    ];

    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 40,
          spreadRadius: 4,
        ),
      ],
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            _WindowTitleBar(
              title: title,
              titleWidget: entry?.config.titleWidget,
              actions: actions,
              onClose: () => Navigator.of(context).maybePop(),
            ),
            Divider(height: 1, color: context.cs.outlineVariant),
            Expanded(
              child: DetachedShellHost(
                hasChrome: true,
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowTitleBar extends StatelessWidget {
  final String title;
  final Widget? titleWidget;
  final List<Widget> actions;
  final VoidCallback onClose;

  const _WindowTitleBar({
    required this.title,
    this.titleWidget,
    required this.actions,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Expanded(
            child:
                titleWidget ??
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: context.cs.onSurface,
                  ),
                ),
          ),
          ...actions,
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
