import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import 'desktop_floating_provider.dart';

/// A panel mounted inside the desktop right sidebar.
///
/// The Vue app opened tool views *inside* the sidebar rather than navigating
/// the main column; [DesktopRightSidebar] renders whichever panel is set here
/// on top of its default content.
@immutable
class SidebarPanel {
  /// Identifies the panel so the strip can mark it active and a second tap on
  /// the same icon can toggle it back off.
  final String id;

  final WidgetBuilder builder;

  /// The back step of the screen open in this panel, which the strip beside it
  /// offers as its back button.
  final SidebarPanelBack back = SidebarPanelBack();

  SidebarPanel({required this.id, required this.builder});
}

/// The back step of the screen open in a right-sidebar panel.
///
/// A panel's back button is not in its own header but at the top of the strip
/// beside it, where Vue drew the sheet's back arrow over the strip. So the
/// screen hands its back step over here — a detail view back to its list, say —
/// and the strip runs it. With nothing handed over, back closes the panel.
class SidebarPanelBack {
  Object? _owner;
  VoidCallback? _step;

  /// Makes [step] the panel's back step, on behalf of [owner].
  void claim(Object owner, VoidCallback step) {
    _owner = owner;
    _step = step;
  }

  /// Drops [owner]'s claim, unless another screen has claimed it since.
  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _step = null;
  }

  /// Runs the claimed back step, or [orElse] when nothing has claimed it.
  void run(VoidCallback orElse) => (_step ?? orElse)();
}

final rightSidebarPanelProvider = StateProvider<SidebarPanel?>((ref) => null);

/// True while a panel occupies the sidebar (Vue's `sidebarState.isOccupied`).
final rightSidebarOccupiedProvider = Provider<bool>(
  (ref) => ref.watch(rightSidebarPanelProvider) != null,
);

void showPanelInRightSidebar(WidgetRef ref, SidebarPanel panel) {
  ref.read(rightSidebarPanelProvider.notifier).state = panel;
}

/// Opens [panel], or closes it when it is already the one on screen.
void togglePanelInRightSidebar(WidgetRef ref, SidebarPanel panel) {
  final notifier = ref.read(rightSidebarPanelProvider.notifier);
  notifier.state = notifier.state?.id == panel.id ? null : panel;
}

void closeRightSidebarPanel(WidgetRef ref) {
  ref.read(rightSidebarPanelProvider.notifier).state = null;
}

/// Marks a screen mounted as a right-sidebar panel, with what leaving it means
/// there: closing the panel. A screen built to be popped off as a route would
/// otherwise pop the app's own page from under the sidebar.
class SidebarPanelScope extends InheritedWidget {
  final VoidCallback onClose;

  /// Where the screen hands over its back step; see [SidebarPanelBack].
  final SidebarPanelBack back;

  const SidebarPanelScope({
    super.key,
    required this.onClose,
    required this.back,
    required super.child,
  });

  static SidebarPanelScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SidebarPanelScope>();

  @override
  bool updateShouldNotify(SidebarPanelScope oldWidget) => false;
}

/// Whether [context] is inside a right-sidebar panel. The sidebar already
/// frames the screen on every side, so what is laid out in it runs edge to
/// edge: no gutters around the list, no rounded cards, only rules between rows.
bool inSidebarPanel(BuildContext context) =>
    SidebarPanelScope.maybeOf(context) != null;

/// Leaves the sheet or screen [context] is in, wherever it is shown: steps its
/// desktop window back (closing it from its root), closes its sidebar panel,
/// or pops its route.
void closeSheet(BuildContext context) {
  if (popDesktopWindow(context)) return;
  final panel = SidebarPanelScope.maybeOf(context);
  if (panel != null) {
    panel.onClose();
    return;
  }
  Navigator.of(context).pop();
}

/// Back action for a tool screen opened with `startExpanded: true`.
///
/// Those screens are reachable two ways: as a `/tools/...` route in the middle
/// column, where "back" returns to the Tools hub, and — on desktop — mounted
/// inside the right sidebar, where "back" must dismiss the panel instead of
/// navigating the whole app.
void closeExpandedToolScreen(BuildContext context, WidgetRef ref) {
  if (ref.read(rightSidebarPanelProvider) != null) {
    closeRightSidebarPanel(ref);
    return;
  }
  GoRouter.of(context).go('/tools');
}
