import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/chat/bridge/chat_bridge_registry.dart';
import '../../../features/chat/widgets/magic_drawer.dart';
import '../../../features/chat/widgets/magic_drawer_widgets.dart';
import '../../../features/tools/tools_screen.dart';
import 'desktop_sidebar_surface.dart';
import '../shell_header_provider.dart';
import 'sidebar_drag_handle.dart';
import 'sidebar_resizer.dart';
import 'sidebar_sheet_provider.dart';
import 'sidebar_tool_panels.dart';

/// Width of the icon strip that sits beside an open panel — Vue's
/// `.magic-drawer-sidebar.icon-only.left-icon-strip`.
const double _stripWidth = 64;

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
    final isChat = charId != null;

    // Collapsed: nothing but the strip — which is the whole point of the
    // collapsed state. It used to be a single decorative icon in chat, which
    // made collapsing the sidebar equivalent to losing the Magic Drawer.
    if (collapsed) {
      return isChat
          ? _buildMagicStrip(charId, key: const ValueKey('strip-collapsed'))
          : _buildToolStrip(context, ref, activeId: panel?.id);
    }

    final background = isChat
        ? MagicDrawerPanel(
            key: ValueKey('magic-$charId'),
            charId: charId,
            // The Ledger diagnostics' "jump to source message" needs the chat
            // WebView, which the sidebar does not own — reach it through the
            // bridge registry the chat screen publishes into.
            onScrollToMessage: (id) async {
              final bridge = ref.read(chatBridgeRegistryProvider(charId));
              await bridge?.scrollToMessage(id, highlight: true);
            },
          )
        : const ToolsScreen(inSidebar: true);

    if (panel == null) {
      return Material(color: Colors.transparent, child: background);
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
          child: isChat
              ? _buildMagicStrip(charId, key: const ValueKey('strip-rail'))
              : _buildToolStrip(context, ref, activeId: panel.id),
        ),
        VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        Expanded(
          child: DetachedShellHost(
            child: Material(
              color: Colors.transparent,
              child: Builder(builder: panel.builder),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMagicStrip(String charId, {Key? key}) {
    return MagicDrawerPanel(key: key, charId: charId, iconOnly: true);
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
