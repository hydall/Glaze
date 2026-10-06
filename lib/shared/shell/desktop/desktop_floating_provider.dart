import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'desktop_layout_provider.dart';
import 'desktop_window_geometry.dart';

/// Views that open as desktop floating windows instead of taking over the
/// middle column or the whole app, each with the route it corresponds to on
/// mobile — or null for a screen phones push without a route of its own, which
/// its caller then does itself (see [floatOnDesktop]).
///
/// A view id may carry arguments as a query, `settings?highlight=language`;
/// [desktopViewName] is the id without them.
const desktopFloatingViews = <String, String?>{
  'menu': '/menu',
  'settings': '/menu/settings',
  'theme-settings': '/menu/themes',
  'theme-editor': null,
  'third-party-providers': null,
  // `?id=<character>`, or `?new=<id>` for a character not yet created.
  'character-editor': null,
  // `?preset=<id>&block=<id>`: works on the preset editor it was opened from.
  'preset-block': null,
  // `?id=<persona>`, or `?new=<id>` for a persona not yet created.
  'persona-editor': null,
  'lorebook-editor': null,
  // `?id=<script>&scope=global|preset|studio[&preset=<id>]`.
  'regex-editor': null,
  'about': '/menu/about',
  'hall-of-fame': '/menu/about/hall-of-fame',
  'logs': '/menu/logs',
  // `?path=<file>`.
  'log-view': null,
  'sync': '/sync',
  'backup': '/menu/settings',
};

/// One floating window: its own navigation stack plus where it sits.
///
/// Every window navigates on its own — tapping "Settings" in a window's Menu
/// pushes onto *that* window's stack, the way the Vue `WindowView` swapped
/// `currentView` — so several can be open side by side without disturbing each
/// other or the middle column.
@immutable
class DesktopWindow {
  final int id;

  /// Views from root to top; never empty. The top one is on screen.
  final List<String> stack;

  /// Where the user put the window, or null while it still sits where it
  /// opened (see [defaultWindowRect] and [cascade]).
  final Rect? rect;

  /// How many windows were already open when this one opened; steps its
  /// default position so a new window does not land exactly on another.
  final int cascade;

  final bool minimized;
  final bool maximized;

  const DesktopWindow({
    required this.id,
    required this.stack,
    this.rect,
    this.cascade = 0,
    this.minimized = false,
    this.maximized = false,
  }) : assert(stack.length > 0);

  String get rootView => stack.first;

  String get activeView => stack.last;

  bool get canGoBack => stack.length > 1;

  DesktopWindow copyWith({
    List<String>? stack,
    Rect? rect,
    bool? minimized,
    bool? maximized,
  }) => DesktopWindow(
    id: id,
    stack: stack ?? this.stack,
    rect: rect ?? this.rect,
    cascade: cascade,
    minimized: minimized ?? this.minimized,
    maximized: maximized ?? this.maximized,
  );
}

/// The open floating windows, back to front: the last visible (not minimized)
/// one is focused and drawn on top. Empty means no window is open.
class DesktopWindowsNotifier extends Notifier<List<DesktopWindow>> {
  int _nextId = 1;

  /// Last geometry of a window per root view, so reopening the Menu puts it
  /// back where the user left it. Kept for the session only.
  final Map<String, Rect> _lastRects = {};

  @override
  List<DesktopWindow> build() => const [];

  bool get isOpen => state.isNotEmpty;

  /// The window keyboard shortcuts act on: the topmost one not minimized.
  DesktopWindow? get focused => topmostVisibleWindow(state);

  DesktopWindow? byId(int id) {
    for (final window in state) {
      if (window.id == id) return window;
    }
    return null;
  }

  /// Brings [viewId] up: focuses a window already showing it (or rooted at
  /// it), or opens a new one. [newWindow] always opens a new one.
  ///
  /// Returns the id of the window that ends up showing the view.
  int open(String viewId, {bool newWindow = false}) {
    if (!newWindow) {
      final existing =
          _firstWhere((w) => w.activeView == viewId) ??
          _firstWhere((w) => w.rootView == viewId);
      if (existing != null) {
        focus(existing.id);
        return existing.id;
      }
    }
    final window = DesktopWindow(
      id: _nextId++,
      stack: [viewId],
      rect: _lastRects[viewId],
      cascade: state.length,
    );
    state = [...state, window];
    return window.id;
  }

  /// Pushes [viewId] on top of window [id]'s stack and focuses it.
  void push(int id, String viewId) {
    final window = byId(id);
    if (window == null) {
      open(viewId);
      return;
    }
    _replace(
      window.copyWith(stack: [...window.stack, viewId], minimized: false),
      toFront: true,
    );
  }

  /// Steps window [id] back one view, closing it from its root.
  void pop(int id) {
    final window = byId(id);
    if (window == null) return;
    if (!window.canGoBack) {
      close(id);
      return;
    }
    _replace(
      window.copyWith(stack: window.stack.sublist(0, window.stack.length - 1)),
    );
  }

  void close(int id) {
    final window = byId(id);
    if (window == null) return;
    final rect = window.rect;
    if (rect != null) _lastRects[window.rootView] = rect;
    state = [
      for (final w in state)
        if (w.id != id) w,
    ];
  }

  /// Closes every window [test] holds for. Safe to call late, from a
  /// callback that may outlive the app (a disposed screen's cleanup).
  void closeWhere(bool Function(DesktopWindow window) test) {
    if (!ref.mounted) return;
    for (final window in [...state]) {
      if (test(window)) close(window.id);
    }
  }

  void closeAll() {
    for (final window in state) {
      final rect = window.rect;
      if (rect != null) _lastRects[window.rootView] = rect;
    }
    state = const [];
  }

  /// Raises window [id] to the top, restoring it if minimized.
  void focus(int id) {
    final window = byId(id);
    if (window == null) return;
    if (identical(focused, window)) return;
    _replace(window.copyWith(minimized: false), toFront: true);
  }

  void minimize(int id) {
    final window = byId(id);
    if (window == null || window.minimized) return;
    _replace(window.copyWith(minimized: true));
  }

  void toggleMaximize(int id) {
    final window = byId(id);
    if (window == null) return;
    _replace(
      window.copyWith(maximized: !window.maximized, minimized: false),
      toFront: true,
    );
  }

  /// Records where the user moved or resized window [id] to.
  void setRect(int id, Rect rect) {
    final window = byId(id);
    if (window == null) return;
    _replace(window.copyWith(rect: rect, maximized: false));
  }

  /// Moves window [id]'s top view out into a window of its own, stepping the
  /// original back. Returns the new window's id, or null when there is nothing
  /// to split off (a window showing only its root).
  int? detach(int id) {
    final window = byId(id);
    if (window == null || !window.canGoBack) return null;
    final viewId = window.activeView;
    _replace(
      window.copyWith(stack: window.stack.sublist(0, window.stack.length - 1)),
    );
    final source = window.rect;
    final detached = DesktopWindow(
      id: _nextId++,
      stack: [viewId],
      rect: source?.shift(const Offset(32, 32)) ?? _lastRects[viewId],
      cascade: state.length,
    );
    state = [...state, detached];
    return detached.id;
  }

  /// Focuses the next window (or, with [backwards], the previous one) — the
  /// Ctrl+Tab switch. Minimized windows take part and are restored.
  void cycle({bool backwards = false}) {
    if (state.length < 2) {
      if (state.isNotEmpty) focus(state.first.id);
      return;
    }
    if (backwards) {
      // Send the top window to the back; the one under it takes focus.
      final top = focused ?? state.last;
      final next = [
        top,
        for (final w in state)
          if (w.id != top.id) w,
      ];
      state = next;
      final newTop = focused;
      if (newTop == null) focus(state.last.id);
    } else {
      focus(state.first.id);
    }
  }

  DesktopWindow? _firstWhere(bool Function(DesktopWindow) test) {
    for (final window in state) {
      if (test(window)) return window;
    }
    return null;
  }

  void _replace(DesktopWindow window, {bool toFront = false}) {
    if (toFront) {
      state = [
        for (final w in state)
          if (w.id != window.id) w,
        window,
      ];
    } else {
      state = [
        for (final w in state)
          if (w.id == window.id) window else w,
      ];
    }
  }
}

final desktopWindowsProvider =
    NotifierProvider<DesktopWindowsNotifier, List<DesktopWindow>>(
      DesktopWindowsNotifier.new,
    );

/// Marks the subtree of floating window [windowId], so a screen inside can
/// navigate within its own window (see [goOrFloat]).
class DesktopWindowScope extends InheritedWidget {
  final int windowId;

  const DesktopWindowScope({
    super.key,
    required this.windowId,
    required super.child,
  });

  static int? idOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DesktopWindowScope>()?.windowId;

  @override
  bool updateShouldNotify(DesktopWindowScope oldWidget) =>
      windowId != oldWidget.windowId;
}

/// Shell-header pseudo-branch that window [windowId]'s screens publish under,
/// so each window's title bar shows its own screen's header. Kept well below
/// `kDetachedChromeBranch` so it cannot collide with it or a real branch.
int desktopWindowHeaderBranch(int windowId) => -1000 - windowId;

/// The topmost window of [windows] (back to front) that is not minimized.
DesktopWindow? topmostVisibleWindow(List<DesktopWindow> windows) {
  for (final window in windows.reversed) {
    if (!window.minimized) return window;
  }
  return null;
}

/// [viewId] without the arguments it may carry (`settings?highlight=x` →
/// `settings`).
String desktopViewName(String viewId) => Uri.parse(viewId).path;

bool isDesktopFloatingView(String viewId) =>
    desktopFloatingViews.containsKey(desktopViewName(viewId));

/// Opens [viewId] in a floating window when the desktop layout is up, and
/// returns whether it did; on phones it does nothing and returns false, so the
/// caller navigates there the phone's way.
///
/// [push] stacks the view onto the window [context] sits in (a menu item
/// drilling in); otherwise the view is brought up in a window of its own.
/// Holding Ctrl (Cmd on macOS) always opens a new window.
bool floatOnDesktop(BuildContext context, String viewId, {bool push = false}) {
  if (!isDesktopLayout(context) || !isDesktopFloatingView(viewId)) {
    return false;
  }
  final windows = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopWindowsProvider.notifier);
  final windowId = DesktopWindowScope.idOf(context);
  final newWindow = isNewWindowModifierPressed;
  if (push && windowId != null && !newWindow) {
    windows.push(windowId, viewId);
  } else {
    windows.open(viewId, newWindow: newWindow);
  }
  return true;
}

/// Opens [viewId] in a floating window on desktop (see [floatOnDesktop]), or
/// navigates to its route on phones.
void goOrFloat(
  BuildContext context,
  String viewId, {
  String? route,
  bool push = false,
}) {
  if (floatOnDesktop(context, viewId, push: push)) return;
  context.push(route ?? desktopFloatingViews[viewId] ?? '/$viewId');
}

/// Whether a floating window opened from [context] would be seen: not from a
/// route pushed over the whole app (a sheet window, a dialog, a full-screen
/// page), which covers the shell the floating windows are drawn in.
bool floatingWindowsVisibleFrom(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null) return true;
  return route.navigator != Navigator.maybeOf(context, rootNavigator: true) ||
      route.isFirst;
}

/// Steps the floating window [context] sits in back one view, closing it from
/// its root. Returns false outside a window, where the caller goes back its own
/// way.
bool popDesktopWindow(BuildContext context) {
  final windowId = DesktopWindowScope.idOf(context);
  if (windowId == null) return false;
  ProviderScope.containerOf(
    context,
    listen: false,
  ).read(desktopWindowsProvider.notifier).pop(windowId);
  return true;
}
