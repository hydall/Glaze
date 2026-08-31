import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import 'desktop_layout_provider.dart';

/// Views that open as the desktop floating window instead of taking over the
/// middle column, keyed by the route segment they correspond to on mobile.
const desktopFloatingViews = <String, String>{
  'menu': '/menu',
  'settings': '/menu/settings',
  'theme-settings': '/menu/themes',
  'about': '/menu/about',
  'sync': '/sync',
  'backup': '/menu/settings',
};

/// The window's own navigation stack. Empty means the window is closed.
///
/// The window used to hold a single view id, so tapping "Settings" inside the
/// floating Menu pushed a route into the *middle column* — the settings screen
/// appeared behind the window while the window kept showing the menu. A stack
/// keeps that navigation inside the window, the way the Vue `WindowView` did by
/// swapping `currentView`.
final desktopFloatingStackProvider = StateProvider<List<String>>((ref) => []);

final desktopFloatingProvider = Provider<DesktopFloatingController>(
  (ref) => DesktopFloatingController(ref),
);

class DesktopFloatingController {
  final Ref _ref;

  DesktopFloatingController(this._ref);

  List<String> get _stack => _ref.read(desktopFloatingStackProvider);

  StateController<List<String>> get _notifier =>
      _ref.read(desktopFloatingStackProvider.notifier);

  String? get activeView => _stack.isEmpty ? null : _stack.last;

  bool get isOpen => _stack.isNotEmpty;

  bool get canGoBack => _stack.length > 1;

  /// Opens [viewId] as the window's root, replacing anything already open.
  void open(String viewId) => _notifier.state = [viewId];

  /// Pushes [viewId] on top of the current window view.
  void push(String viewId) => _notifier.state = [..._stack, viewId];

  void pop() {
    final stack = _stack;
    if (stack.length <= 1) {
      close();
      return;
    }
    _notifier.state = stack.sublist(0, stack.length - 1);
  }

  void close() => _notifier.state = const [];
}

bool isDesktopFloatingView(String viewId) =>
    desktopFloatingViews.containsKey(viewId);

/// Opens [viewId] in the floating window on desktop, or navigates to its route
/// on phones.
///
/// [push] stacks the view on top of what the window already shows (a menu item
/// drilling in); the default replaces the stack (opening the window fresh).
void goOrFloat(
  BuildContext context,
  WidgetRef ref,
  String viewId, {
  String? route,
  bool push = false,
}) {
  final target = route ?? desktopFloatingViews[viewId] ?? '/$viewId';
  if (isDesktopLayout(context) && isDesktopFloatingView(viewId)) {
    final controller = ref.read(desktopFloatingProvider);
    if (push && controller.isOpen) {
      controller.push(viewId);
    } else {
      controller.open(viewId);
    }
    return;
  }
  context.push(target);
}
