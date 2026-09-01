import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/chat/services/magic_drawer_actions.dart';
import '../../../features/chat/services/magic_drawer_layout_service.dart';
import '../../../features/chat/state/magic_drawer_stats_cache.dart';
import '../../../features/chat/widgets/magic_drawer.dart';
import '../../../features/chat/widgets/magic_drawer_models.dart';
import '../../../features/tools/tools_screen.dart';
import 'desktop_tool_strip.dart';
import 'sidebar_drag_handle.dart';
import 'sidebar_resizer.dart';
import 'sidebar_sheet_provider.dart';

class DesktopRightSidebar extends ConsumerStatefulWidget {
  const DesktopRightSidebar({super.key});

  @override
  ConsumerState<DesktopRightSidebar> createState() =>
      _DesktopRightSidebarState();
}

class _DesktopRightSidebarState extends ConsumerState<DesktopRightSidebar> {
  /// Quick Access order, resolved once so the chat strip can show the same
  /// entries (and the same order) as the full panel. Null until the first load
  /// lands; the strip falls back to the default catalogue meanwhile.
  List<String>? _quickAccessIds;

  @override
  void initState() {
    super.initState();
    _loadQuickAccessLayout();
  }

  Future<void> _loadQuickAccessLayout() async {
    final cached = ref.read(magicDrawerLayoutCacheProvider);
    if (cached != null) {
      setState(() => _quickAccessIds = cached.itemIds);
      return;
    }
    final layout = await MagicDrawerLayoutService(
      ref,
    ).loadLayout(MagicDrawerActions.all);
    if (!mounted) return;
    setState(() => _quickAccessIds = layout.itemIds);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(rightSidebarControllerProvider);
    final sheet = ref.watch<Widget?>(rightSidebarSheetProvider);
    final location = GoRouterState.of(context).uri.toString();
    final isChat = location.startsWith('/chat/');
    final collapsed = controller.collapsed;

    // Keep the strip's copy of the Quick Access order in step with edits made
    // in the full panel (reorder, remove, re-add).
    ref.listen(magicDrawerLayoutCacheProvider, (_, next) {
      if (next != null && mounted) {
        setState(() => _quickAccessIds = next.itemIds);
      }
    });

    // Auto-expand / restore for sheets
    if (sheet != null && collapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.autoExpand();
      });
    }
    if (sheet == null && controller.wasAutoExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.restoreCollapse();
      });
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Container(
        width: controller.width,
        // No extra tint in chat: it would band the chat's own background at
        // the left and right edges instead of carrying straight through.
        color: isChat ? null : Colors.black.withValues(alpha: 0.2),
        child: Stack(
          children: [
            if (sheet != null)
              _buildSheetHost(sheet, isChat, location, controller.collapsed)
            else if (controller.collapsed)
              _buildStrip(isChat, location)
            else
              _buildExpanded(isChat, location),
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              child: SidebarDragHandle.right(rightController: controller),
            ),
          ],
        ),
      ),
    );
  }

  /// A sheet open in the sidebar. While the sidebar is expanded the icon strip
  /// pins itself to the sheet's left edge (Vue's `.left-icon-strip`) so the
  /// other entries stay reachable — Tools and chat Quick Access alike. A
  /// collapsed sidebar has no room for both, so the sheet takes it all.
  Widget _buildSheetHost(
    Widget sheet,
    bool isChat,
    String location,
    bool collapsed,
  ) {
    final host = Material(color: Colors.transparent, child: sheet);
    if (collapsed) return host;

    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(left: DesktopToolStrip.overlayWidth),
            child: host,
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          width: DesktopToolStrip.overlayWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
              ),
            ),
            // Clears the sheet header, exactly as `.left-icon-strip`'s 56px
            // top padding does in the Vue build.
            child: _buildStrip(isChat, location, topPadding: 56),
          ),
        ),
      ],
    );
  }

  Widget _buildExpanded(bool isChat, String location) {
    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: isChat ? _buildChatPanel(location) : const ToolsScreen(),
      ),
    );
  }

  Widget _buildChatPanel(String location) {
    final charId = _extractCharId(location);
    if (charId == null) return const SizedBox.shrink();
    return MagicDrawerPanel(charId: charId);
  }

  /// The icon strip for whichever mode the sidebar is in. Chat shows Quick
  /// Access, everything else shows Tools — the two were built separately
  /// before, which is why only Tools had a working strip.
  Widget _buildStrip(bool isChat, String location, {double topPadding = 0}) {
    final items = isChat
        ? _quickAccessItems(location)
        : _toolStripItems(location);
    return DesktopToolStrip(
      items: items,
      activeId: isChat ? null : _activeToolId(location),
      topPadding: topPadding,
    );
  }

  // ── Tools mode ──────────────────────────────────────────────────────────

  static const _toolRoutes = <({String id, IconData icon, String label})>[
    (id: 'personas', icon: Icons.manage_accounts, label: 'Personas'),
    (id: 'presets', icon: Icons.description, label: 'Presets'),
    (id: 'api', icon: Icons.cloud, label: 'API'),
    (id: 'lorebooks', icon: Icons.library_books, label: 'Lorebooks'),
    (id: 'regex', icon: Icons.code, label: 'Regex'),
  ];

  List<DesktopToolStripItem> _toolStripItems(String location) {
    return _toolRoutes
        .map(
          (tool) => DesktopToolStripItem(
            id: tool.id,
            icon: tool.icon,
            label: tool.label,
            onTap: () => context.push('/tools/${tool.id}'),
          ),
        )
        .toList();
  }

  String? _activeToolId(String location) {
    for (final tool in _toolRoutes) {
      if (location.contains('/tools/${tool.id}')) return tool.id;
    }
    return null;
  }

  // ── Chat mode (Quick Access) ────────────────────────────────────────────

  List<DesktopToolStripItem> _quickAccessItems(String location) {
    final charId = _extractCharId(location);
    if (charId == null) return const [];

    final ids = _quickAccessIds;
    final defs = ids == null
        ? MagicDrawerActions.all
        : ids
              .map(
                (id) => MagicDrawerActions.all
                    .where((item) => item.id == id)
                    .firstOrNull,
              )
              .whereType<MagicDrawerItemDef>()
              .toList();

    final actions = MagicDrawerActions(charId: charId);
    return defs
        .map(
          (def) => DesktopToolStripItem(
            id: def.id,
            icon: def.icon,
            label: def.label,
            onTap: () => actions.handleTap(context, ref, def),
          ),
        )
        .toList();
  }

  String? _extractCharId(String location) {
    // Parse the URI so query parameters (e.g. ?session=1) are NOT included
    // in the charId. The previous regex `/chat/([^/]+)` captured the query
    // string too, producing a polluted charId like "mq9ua9qr?session=1" that
    // created phantom chatProvider instances and phantom DB sessions.
    final uri = Uri.parse(location);
    final segments = uri.pathSegments;
    if (segments.length >= 2 && segments[0] == 'chat') {
      return segments[1];
    }
    return null;
  }
}
