import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/desktop_window.dart';
import '../../../features/chat/bridge/chat_bridge_registry.dart';
import '../../../features/chat/widgets/chat_drawer_panel.dart';
import '../../../features/chat/widgets/magic_drawer_widgets.dart';
import '../../../features/tools/tools_screen.dart';
import '../../theme/app_colors.dart';
import 'desktop_sidebar_surface.dart';
import '../shell_header_provider.dart';
import 'sidebar_drag_handle.dart';
import 'sidebar_resizer.dart';
import 'sidebar_sheet_provider.dart';
import 'sidebar_tool_panels.dart';

/// Width of the icon strip that sits beside an open panel — Vue's
/// `.magic-drawer-sidebar.icon-only.left-icon-strip`.
const double _stripWidth = 64;

/// Height of the back button over the strip: the open panel's header row (a
/// flush [GlazeAppBar]), which the button lines up with.
const double _stripBackHeight = 56;

class DesktopRightSidebar extends ConsumerWidget {
  /// See [DesktopLeftSidebar.width].
  final double width;

  const DesktopRightSidebar({super.key, required this.width});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(rightSidebarControllerProvider);
    final panel = ref.watch(rightSidebarPanelProvider);
    final location = GoRouterState.of(context).uri;
    final charId = _extractCharId(location);
    // A panel needs room, so borrow the expanded width while one is open and
    // give it back when it closes (Vue's wasAutoExpanded dance).
    if (panel != null && controller.collapsed) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => controller.autoExpand(),
      );
    }
    if (panel == null && controller.wasAutoExpanded) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => controller.restoreCollapse(),
      );
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => DesktopSidebarSurface(
        width: width,
        edge: SidebarEdge.right,
        animate: !controller.dragging,
        child: Stack(
          children: [
            Positioned.fill(child: _buildBody(context, ref, panel, charId)),
            Positioned(
              top: 0,
              bottom: 0,
              left: -SidebarDragHandle.width / 2,
              child: SidebarDragHandle.right(rightController: controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    SidebarPanel? panel,
    String? charId,
  ) {
    final collapsed = width < kSidebarCollapseThreshold;
    if (charId != null) {
      return _buildChatBody(context, ref, panel, charId, collapsed: collapsed);
    }

    // Collapsed: nothing but the strip — which is the whole point of the
    // collapsed state.
    if (collapsed) return _buildToolStrip(context, ref, activeId: panel?.id);

    if (panel == null) {
      return const Material(
        color: Colors.transparent,
        child: ToolsScreen(inSidebar: true),
      );
    }

    // Expanded with a panel: the strip shrinks to a rail on the left and the
    // panel takes the rest, so switching tools never needs a round trip
    // through the hub.
    return Row(
      // Stretch, not the default centre: the strip shrink-wraps its icons, so
      // a centred row floated the rail into the middle of the sidebar with a
      // gap above it. Vue's `.left-icon-strip` is pinned top-to-bottom and its
      // icons stack from the top.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _stripWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StripBackButton(panel: panel),
              Expanded(
                child: _buildToolStrip(context, ref, activeId: panel.id),
              ),
            ],
          ),
        ),
        ..._buildPanel(context, ref, panel),
      ],
    );
  }

  /// The chat's Magic Drawer: a list, which shrinks to a strip of its icons
  /// beside an open card's screen and in the collapsed sidebar.
  ///
  /// The list and the strip are one drawer, kept mounted at the head of the
  /// row in every state and only told to drop its labels — its rows, their
  /// height and its scroll are the same either way, so every icon stays where
  /// the list drew it. (Collapsing the sidebar to a width other than the
  /// strip's moves them sideways, to the middle of it.)
  Widget _buildChatBody(
    BuildContext context,
    WidgetRef ref,
    SidebarPanel? panel,
    String charId, {
    required bool collapsed,
  }) {
    final showPanel = panel != null && !collapsed;
    final drawer = ChatDrawerPanel(
      key: ValueKey('magic-$charId'),
      charId: charId,
      // The app's title bar draws the edge above the sidebar.
      showTopBorder: !usesCustomAppTitleBar,
      listLayout: true,
      rail: collapsed || showPanel,
      // The Ledger diagnostics' "jump to source message" needs the chat
      // WebView, which the sidebar does not own — reach it through the
      // bridge registry the chat screen publishes into.
      onScrollToMessage: (id) async {
        final bridge = ref.read(chatBridgeRegistryProvider(charId));
        await bridge?.scrollToMessage(id, highlight: true);
      },
    );
    return Material(
      color: Colors.transparent,
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The same widgets at the head of the row in every state, so the
            // drawer is updated in place rather than built anew.
            SizedBox(
              width: showPanel ? _stripWidth : constraints.maxWidth,
              child: Stack(
                children: [
                  Positioned.fill(child: drawer),
                  // In the room the drawer's tabs leave above the strip.
                  if (showPanel)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _StripBackButton(panel: panel),
                    ),
                ],
              ),
            ),
            if (showPanel) ..._buildPanel(context, ref, panel),
          ],
        ),
      ),
    );
  }

  /// An open panel and the rule between it and the strip on its left.
  List<Widget> _buildPanel(
    BuildContext context,
    WidgetRef ref,
    SidebarPanel panel,
  ) {
    return [
      VerticalDivider(
        width: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      Expanded(
        child: DetachedShellHost(
          child: Material(
            color: Colors.transparent,
            child: SidebarPanelScope(
              onClose: () => closeRightSidebarPanel(ref),
              back: panel.back,
              child: Builder(builder: panel.builder),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _buildToolStrip(
    BuildContext context,
    WidgetRef ref, {
    String? activeId,
  }) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tool in sidebarTools)
              MagicDrawerStripIcon(
                icon: tool.icon,
                label: tool.label(),
                active: activeId == tool.id,
                onTap: () => togglePanelInRightSidebar(ref, tool.panel),
              ),
          ],
        ),
      ),
    );
  }

  /// Parses the URI so query parameters (e.g. `?session=1`) are NOT included in
  /// the charId. A regex over the raw location captured the query string too,
  /// producing a polluted charId like `mq9ua9qr?session=1` that created phantom
  /// chatProvider instances and phantom DB sessions.
  String? _extractCharId(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.length >= 2 && segments[0] == 'chat') return segments[1];
    return null;
  }
}

/// The open panel's back button, over the strip beside it — where Vue drew the
/// sheet's back arrow, its header running across the strip. It takes the
/// panel header's row and lines up with it; the panel's own header draws none.
class _StripBackButton extends ConsumerWidget {
  final SidebarPanel panel;

  const _StripBackButton({required this.panel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: _stripBackHeight,
      alignment: Alignment.center,
      decoration: usesCustomAppTitleBar
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.cs.outlineVariant),
              ),
            )
          : null,
      child: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        color: context.cs.primary,
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: () => panel.back.run(() => closeRightSidebarPanel(ref)),
      ),
    );
  }
}
