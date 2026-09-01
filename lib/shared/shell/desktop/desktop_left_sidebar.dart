import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/haptics.dart';
import '../../../core/state/character_provider.dart';
import '../../../features/chat_history/chat_history_list.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/hover_glow.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../shell_navigation_provider.dart';
import 'desktop_floating_provider.dart';
import 'desktop_glossary_popup.dart';
import 'desktop_layout_provider.dart';
import 'desktop_sidebar_surface.dart';
import 'sidebar_drag_handle.dart';
import 'sidebar_resizer.dart';

/// Branch indices of the shell's [StatefulShellRoute], mirrored here because
/// the sidebar sits outside the shell (see [shellNavigationProvider]).
const int _charactersBranch = 1;
const int _menuBranch = 3;

class DesktopLeftSidebar extends ConsumerStatefulWidget {
  /// Which entry reads as active: `characters`, `chat`, `tools`, `menu`,
  /// `dialogs`, or empty for none. Supplied by `DesktopShell` from the route.
  final String currentView;

  /// Width to render at. Normally the controller's stored width, but the shell
  /// shrinks it when the window cannot afford both sidebars plus a usable
  /// middle column — otherwise an 800px window left ~200px for the content.
  final double width;

  const DesktopLeftSidebar({
    super.key,
    this.currentView = '',
    required this.width,
  });

  @override
  ConsumerState<DesktopLeftSidebar> createState() => _DesktopLeftSidebarState();
}

class _DesktopLeftSidebarState extends ConsumerState<DesktopLeftSidebar> {
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Secret gesture: tapping Characters [kRevealHiddenTapCount] times within
  /// [kRevealHiddenTapWindow] reveals hidden characters.
  void _registerCharactersTabTap() {
    final revealed = ref
        .read(revealHiddenCharactersProvider.notifier)
        .registerCharactersTabTap();
    if (revealed == null || !mounted) return;
    Haptics.heavyImpact();
    GlazeToast.show(
      context,
      revealed ? 'hidden_chars_revealed'.tr() : 'hidden_chars_hidden'.tr(),
    );
  }

  void _openCharacters() {
    _registerCharactersTabTap();
    goShellBranch(
      context,
      ref,
      _charactersBranch,
      fallbackLocation: '/characters',
    );
  }

  /// The Vue sidebar's "New Chat" opened a character picker; the closest
  /// equivalent here is the characters branch reset to its list, from which a
  /// tap starts a fresh session.
  void _startNewChat() {
    goShellBranch(
      context,
      ref,
      _charactersBranch,
      fallbackLocation: '/characters',
    );
  }

  void _toggleGlossary() {
    if (isDesktopLayout(context)) {
      // Opening from here starts at the category list, so clear whatever term
      // a help tip left behind.
      if (ref.read(glossaryPopupVisibleProvider)) {
        ref.read(glossaryPopupVisibleProvider.notifier).state = false;
      } else {
        openGlossaryPopup(ref);
      }
    } else {
      context.go('/menu/glossary');
    }
  }

  void _openMenu() {
    if (isDesktopLayout(context)) {
      ref.read(desktopFloatingProvider).open('menu');
    } else {
      goShellBranch(context, ref, _menuBranch, fallbackLocation: '/menu');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(leftSidebarControllerProvider);
    final glossaryOpen = ref.watch(glossaryPopupVisibleProvider);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildContent(context, controller, glossaryOpen),
    );
  }

  Widget _buildContent(
    BuildContext context,
    LeftSidebarController controller,
    bool glossaryOpen,
  ) {
    final collapsed = widget.width < kSidebarCollapseThreshold;

    // Order matches the Vue sidebar in BOTH modes: the two primary entries on
    // top, the chat list in the middle, the two secondary entries at the
    // bottom. Previously the expanded layout moved Characters to the bottom
    // and dropped New Chat entirely.
    final top = <_NavItem>[
      _NavItem(
        label: 'tab_characters'.tr(),
        icon: Icons.people_rounded,
        active: widget.currentView == 'characters',
        prominent: true,
        onTap: _openCharacters,
      ),
      _NavItem(
        label: 'btn_new_chat'.tr(),
        icon: Icons.add_comment_rounded,
        accent: true,
        onTap: _startNewChat,
      ),
    ];
    final bottom = <_NavItem>[
      _NavItem(
        label: 'menu_glossary'.tr(),
        icon: Icons.info_outline_rounded,
        active: glossaryOpen,
        onTap: _toggleGlossary,
      ),
      _NavItem(
        label: 'tab_more'.tr(),
        icon: Icons.menu_rounded,
        active: widget.currentView == 'menu',
        onTap: _openMenu,
      ),
    ];

    return DesktopSidebarSurface(
      width: widget.width,
      edge: SidebarEdge.left,
      animate: !controller.dragging,
      child: Stack(
        children: [
          if (collapsed)
            _buildCollapsed(context, top, bottom)
          else
            _buildExpanded(context, top, bottom),
          Positioned(
            top: 0,
            bottom: 0,
            // Straddles the divider instead of eating into the content.
            right: -SidebarDragHandle.width / 2,
            child: SidebarDragHandle.left(leftController: controller),
          ),
        ],
      ),
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    List<_NavItem> top,
    List<_NavItem> bottom,
  ) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          for (final item in top) _SidebarButton(item: item),
          Divider(height: 1, color: context.cs.outlineVariant),
          _buildSearchField(context),
          Divider(height: 1, color: context.cs.outlineVariant),
          Expanded(child: ChatHistoryList(searchQuery: _searchQuery)),
          Divider(height: 1, color: context.cs.outlineVariant),
          for (final item in bottom) _SidebarButton(item: item),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return TextField(
      controller: _searchCtrl,
      onChanged: (v) => setState(() => _searchQuery = v),
      textInputAction: TextInputAction.search,
      cursorColor: context.cs.primary,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'search_dialogs'.tr(),
        hintStyle: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: context.cs.onSurfaceVariant),
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 18,
          color: context.cs.primary,
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 0),
        suffixIcon: _searchQuery.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _searchQuery = '');
                },
              )
            : null,
        filled: true,
        fillColor: Colors.transparent,
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
        enabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }

  Widget _buildCollapsed(
    BuildContext context,
    List<_NavItem> top,
    List<_NavItem> bottom,
  ) {
    return Column(
      children: [
        const SizedBox(height: 8),
        for (final item in top) _CollapsedIcon(item: item),
        const SizedBox(height: 4),
        Divider(height: 1, color: context.cs.outlineVariant),
        const Expanded(child: ChatHistoryList(collapsed: true)),
        Divider(height: 1, color: context.cs.outlineVariant),
        for (final item in bottom) _CollapsedIcon(item: item),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _NavItem {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  /// Rendered in full-strength text when idle (Vue's `.desktop-chars-btn`)
  /// rather than the muted tone used by the secondary entries.
  final bool prominent;

  /// Rendered in the accent colour when idle (Vue's `.desktop-new-chat-btn`).
  final bool accent;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.prominent = false,
    this.accent = false,
  });
}

Color _itemColor(BuildContext context, _NavItem item) {
  if (item.active || item.accent) return context.cs.primary;
  return item.prominent ? context.cs.onSurface : context.cs.onSurfaceVariant;
}

/// Expanded sidebar row with the mouse-tracking glow (ported from v-hover-glow).
class _SidebarButton extends StatelessWidget {
  final _NavItem item;

  const _SidebarButton({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = _itemColor(context, item);
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      // Opaque: HoverGlow's overlays are IgnorePointer and the row's own
      // content only covers the icon and the label, so a deferToChild detector
      // would swallow clicks landing on the empty space between them.
      behavior: HitTestBehavior.opaque,
      onTap: item.onTap,
      child: HoverGlow(
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(item.icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (item.prominent || item.accent
                                ? textTheme.labelLarge
                                : textTheme.labelMedium)
                            ?.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsedIcon extends StatelessWidget {
  final _NavItem item;

  const _CollapsedIcon({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = _itemColor(context, item);

    return Tooltip(
      message: item.label,
      preferBelow: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          // The active tint sits *under* the glow: putting it inside HoverGlow
          // would make it the child that paints over the light pool.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.active)
                    ColoredBox(
                      color: context.cs.primary.withValues(alpha: 0.15),
                    ),
                  HoverGlow(
                    child: Center(
                      child: Icon(item.icon, size: 22, color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
