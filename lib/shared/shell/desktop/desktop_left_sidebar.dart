import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _searchQuery = '');
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
      ref.read(desktopWindowsProvider.notifier).open('menu');
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
    // top (Characters as a tile beside New Chat), the chat list in the middle,
    // the two secondary entries at the bottom.
    final characters = _NavItem(
      label: 'tab_characters'.tr(),
      icon: Icons.people_rounded,
      active: widget.currentView == 'characters',
      prominent: true,
      onTap: _openCharacters,
    );
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
            _buildCollapsed(context, characters, bottom)
          else
            _buildExpanded(context, characters, bottom),
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
    _NavItem characters,
    List<_NavItem> bottom,
  ) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: _CharactersButton(item: characters),
          ),
          Expanded(
            child: ChatHistoryList(
              searchQuery: _searchQuery,
              belowCount: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: _buildSearchField(context),
              ),
            ),
          ),
          Divider(height: 1, color: context.cs.outlineVariant),
          for (final item in bottom) _SidebarButton(item: item),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.cs.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      // Escape clears the search, as the close button does.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
        },
        child: SizedBox(
          height: 36,
          child: Center(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              textInputAction: TextInputAction.search,
              cursorColor: context.cs.primary,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'search_dialogs'.tr(),
                hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.cs.onSurfaceVariant,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 0,
                ),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        padding: EdgeInsets.zero,
                        onPressed: _clearSearch,
                      ),
                suffixIconConstraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 32,
                ),
                filled: false,
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsed(
    BuildContext context,
    _NavItem characters,
    List<_NavItem> bottom,
  ) {
    return Column(
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _CharactersTile(item: characters),
        ),
        const SizedBox(height: 4),
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

  const _NavItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.prominent = false,
  });
}

Color _itemColor(BuildContext context, _NavItem item) {
  if (item.active) return context.cs.primary;
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
                        (item.prominent
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

/// Characters as a square button on a filled background, the way Discord's
/// direct-messages button heads its server list. The screen's title already
/// says "Characters", so a second row with the word would only repeat it.
class _CharactersTile extends StatelessWidget {
  static const double _size = 40;

  final _NavItem item;

  const _CharactersTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: item.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(
            dimension: _size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  color: item.active
                      ? context.cs.primary
                      : context.cs.onSurface.withValues(alpha: 0.08),
                ),
                HoverGlow(
                  child: Center(
                    child: Icon(
                      item.icon,
                      size: 22,
                      color: item.active
                          ? context.cs.onPrimary
                          : context.cs.primary,
                    ),
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

/// Characters across the full width of the expanded sidebar, with no fill of
/// its own: the open section shows in the accent colour, as the other entries
/// do. Collapsed, the sidebar shows it as [_CharactersTile].
class _CharactersButton extends StatelessWidget {
  final _NavItem item;

  const _CharactersButton({required this.item});

  @override
  Widget build(BuildContext context) {
    final foreground = _itemColor(context, item);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: item.onTap,
      child: HoverGlow(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: _CharactersTile._size,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(item.icon, size: 20, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: foreground),
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
