import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

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

  const SidebarPanel({required this.id, required this.builder});
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
