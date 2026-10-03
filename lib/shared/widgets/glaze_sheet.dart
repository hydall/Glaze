import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/desktop/desktop_active_surface_provider.dart';
import '../shell/desktop/desktop_layout_provider.dart';
import '../shell/desktop/desktop_window_chrome.dart';
import '../shell/desktop/desktop_window_geometry.dart';
import '../shell/shell_header_provider.dart';

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
/// floating window instead of a full-width band sliding in from the bottom. A
/// window with [windowChrome] leaves what is behind it undimmed; a chrome-less
/// one dims it with [barrierColor].
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

  // A window with a title bar is one window among the others on the desktop
  // and dims nothing behind it: its glass would show that dimming through and
  // read darker than every other window. A chrome-less picker is solid, and
  // keeps the dim that sets it apart.
  @override
  Color? get barrierColor => chrome ? null : barrier;

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
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
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
class GlazeSheetWindow extends ConsumerStatefulWidget {
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
  ConsumerState<GlazeSheetWindow> createState() => _GlazeSheetWindowState();
}

/// A window with [GlazeSheetWindow.chrome] can be dragged by its title bar; a
/// fixed-height one can also be resized from its edges and maximized
/// (double-click the title bar). A content-sized window follows its content's
/// height, so it only moves. Chrome-less windows are short-lived pickers and
/// stay put.
class _GlazeSheetWindowState extends ConsumerState<GlazeSheetWindow> {
  /// Header pseudo-branches handed out to sheet windows, so a window opened
  /// over another does not take over the title bar of the one below. Counts
  /// down from [kDetachedChromeBranch], well clear of the floating windows'
  /// branches.
  static int _branchCounter = 0;

  late final int _headerBranch =
      kDetachedChromeBranch - 1 - (_branchCounter++ % 500);

  /// Where the user moved or resized a fixed-height window to.
  Rect? _rect;
  bool _maximized = false;

  /// How far the user dragged a content-sized window off center.
  Offset _offset = Offset.zero;
  Offset _moveStart = Offset.zero;

  /// Cached for [dispose], where reading `ref` is unsafe.
  late final DesktopActiveSurfaceNotifier _surfaces;

  @override
  void initState() {
    super.initState();
    _surfaces = ref.read(desktopActiveSurfaceProvider.notifier);
    // A window with a title bar takes part in the active-window highlight:
    // it opens active and hands it back when it closes. Deferred, because
    // providers cannot change while the tree is building.
    if (widget.chrome) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _surfaces.activate(this);
      });
    }
  }

  @override
  void dispose() {
    if (widget.chrome) {
      final surfaces = _surfaces;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => surfaces.release(this),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlazeSheetWindowScope(
      contentSized: widget.contentSized,
      // The route lives on the root navigator, above the shell's [DesktopScope].
      // Re-provide it so a sheet opened from inside this window (a nested
      // GlazeBottomSheet, say) still opens as a window instead of a bottom
      // sheet.
      child: DesktopScope(
        isDesktop: true,
        // Kept clear of the top inset — the app's own title bar on Windows,
        // the status bar on a tablet — the way the desktop shell's columns
        // are, so a window never slides under it.
        child: Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _buildPlaced(context, constraints.biggest),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaced(BuildContext context, Size bounds) {
    final width = bounds.width * 0.92 < kGlazeSheetWindowMaxWidth
        ? bounds.width * 0.92
        : kGlazeSheetWindowMaxWidth;
    final maxHeight = bounds.height * _kGlazeSheetWindowHeightFactor;
    final resizable = widget.chrome && !widget.contentSized;

    final Widget framed = widget.chrome
        ? _WindowFrame(
            surface: this,
            headerBranch: _headerBranch,
            fallbackTitle: widget.fallbackTitle,
            fallbackActions: widget.fallbackActions,
            maximized: _maximized,
            onToggleMaximize: resizable ? _toggleMaximize : null,
            child: widget.child,
          )
        : _SheetPanel(child: widget.child);

    if (resizable) {
      final rect = _maximized
          ? Offset.zero & bounds
          : clampWindowRect(
              _rect ??
                  defaultWindowRect(
                    bounds,
                    Size(kGlazeSheetWindowMaxWidth, maxHeight),
                  ),
              bounds,
            );
      return Stack(
        children: [
          DesktopWindowGeometry(
            rect: rect,
            bounds: bounds,
            movable: !_maximized,
            resizable: !_maximized,
            onChanged: (rect) => setState(() => _rect = rect),
            onToggleMaximize: _toggleMaximize,
            child: framed,
          ),
        ],
      );
    }

    final sized = SizedBox(
      width: width,
      child: widget.contentSized
          ? ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: framed,
            )
          : SizedBox(height: maxHeight, child: framed),
    );
    if (!widget.chrome) return Center(child: sized);

    return CustomSingleChildLayout(
      delegate: _OffsetCenterLayout(_offset),
      child: DesktopWindowMoveScope(
        onMoveStart: () => _moveStart = _offset,
        onMoveUpdate: (delta) => setState(() {
          final raw = _moveStart + delta;
          // Loose cap only; the layout delegate does the exact clamping once
          // it knows the window's height.
          _offset = Offset(
            raw.dx.clamp(-bounds.width / 2, bounds.width / 2),
            raw.dy.clamp(-bounds.height / 2, bounds.height / 2),
          );
        }),
        onMoveEnd: () {},
        child: sized,
      ),
    );
  }

  void _toggleMaximize() => setState(() => _maximized = !_maximized);
}

/// Centers its child, shifted by [offset] and kept where its title bar stays
/// reachable (see [clampWindowRect]).
class _OffsetCenterLayout extends SingleChildLayoutDelegate {
  final Offset offset;

  const _OffsetCenterLayout(this.offset);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final centered = Rect.fromCenter(
      center: size.center(Offset.zero) + offset,
      width: childSize.width,
      height: childSize.height,
    );
    return clampWindowRect(centered, size, minSize: Size.zero).topLeft;
  }

  @override
  bool shouldRelayout(_OffsetCenterLayout oldDelegate) =>
      offset != oldDelegate.offset;
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
  /// This window's key in [desktopActiveSurfaceProvider].
  final Object surface;
  final int headerBranch;
  final String? fallbackTitle;
  final List<Widget>? fallbackActions;
  final bool maximized;
  final VoidCallback? onToggleMaximize;
  final Widget child;

  const _WindowFrame({
    required this.surface,
    required this.headerBranch,
    this.fallbackTitle,
    this.fallbackActions,
    this.maximized = false,
    this.onToggleMaximize,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(
      shellHeaderProvider.select((e) => resolveShellHeader(e, headerBranch)),
    );
    final active = ref.watch(desktopSurfaceActiveProvider(surface));
    final title = entry?.config.title ?? fallbackTitle ?? '';
    final actions = <Widget>[...?entry?.config.actions, ...?fallbackActions];

    return Listener(
      // Same as a floating window: any press inside makes it the active one.
      onPointerDown: (_) =>
          ref.read(desktopActiveSurfaceProvider.notifier).activate(surface),
      child: DesktopWindowFrame(
        active: active,
        maximized: maximized,
        titleBar: DesktopWindowMoveArea(
          child: DesktopWindowTitleBar(
            title: title,
            titleWidget: entry?.config.titleWidget,
            actions: actions,
            active: active,
            maximized: maximized,
            onToggleMaximize: onToggleMaximize,
            onClose: () => Navigator.of(context).maybePop(),
          ),
        ),
        child: DetachedShellHost(
          hasChrome: true,
          headerBranch: headerBranch,
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            child: child,
          ),
        ),
      ),
    );
  }
}
