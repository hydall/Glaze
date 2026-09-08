import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/haptics.dart';
import '../../../core/state/character_provider.dart';
import '../../../features/chat_history/chat_history_list.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_toast.dart';
import 'desktop_floating_provider.dart';
import 'desktop_glossary_popup.dart';
import 'desktop_layout_provider.dart';
import 'sidebar_drag_handle.dart';
import 'sidebar_resizer.dart';

class DesktopLeftSidebar extends ConsumerStatefulWidget {
  final String currentView;
  final void Function(String)? onViewChanged;

  const DesktopLeftSidebar({
    super.key,
    this.currentView = '',
    this.onViewChanged,
  });

  @override
  ConsumerState<DesktopLeftSidebar> createState() =>
      _DesktopLeftSidebarState();
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

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(leftSidebarControllerProvider);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildContent(context, controller),
    );
  }

  Widget _buildContent(BuildContext context, LeftSidebarController controller) {
    final collapsed = controller.collapsed;

    final sidebarItems = [
      _NavItem(
        id: 'characters',
        label: 'tab_characters'.tr(),
        icon: Icons.people_rounded,
        active: widget.currentView == 'characters',
        onTap: () {
          _registerCharactersTabTap();
          widget.onViewChanged?.call('characters');
          context.go('/characters');
        },
      ),
      _NavItem(
        id: 'new-chat',
        label: 'btn_new_chat'.tr(),
        icon: Icons.add_comment_rounded,
        onTap: () => context.go('/characters'),
      ),
      _NavItem(
        id: 'glossary',
        label: 'menu_glossary'.tr(),
        icon: Icons.info_outline_rounded,
        onTap: () {
          if (isDesktopLayout(context)) {
            ref.read(glossaryPopupVisibleProvider.notifier).update((v) => !v);
          } else {
            context.go('/menu/glossary');
          }
        },
      ),
      _NavItem(
        id: 'more',
        label: 'tab_more'.tr(),
        icon: Icons.menu_rounded,
        active: widget.currentView == 'menu',
        onTap: () {
          if (isDesktopLayout(context)) {
            ref.read(desktopFloatingProvider).open('menu');
          } else {
            widget.onViewChanged?.call('menu');
            context.go('/menu');
          }
        },
      ),
    ];

    return Container(
      width: controller.width,
      color: Colors.black.withValues(alpha: 0.2),
      child: Stack(
        children: [
          if (collapsed)
            _buildCollapsed(context, sidebarItems)
          else
            _buildExpanded(context, sidebarItems),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: SidebarDragHandle.left(leftController: controller),
          ),
        ],
      ),
    );
  }

  Widget _buildExpanded(BuildContext context, List<_NavItem> items) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          // Search bar — no outer padding, flush with sidebar edges
          TextField(
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
          ),
          Divider(height: 1, color: context.cs.outlineVariant),
          Expanded(child: ChatHistoryList(searchQuery: _searchQuery)),
          Divider(height: 1, color: context.cs.outlineVariant),
          // Characters, Glossary, More — stacked vertically
          _HoverGlowButton(
            icon: items[0].icon,
            label: items[0].label,
            active: items[0].active,
            onTap: items[0].onTap,
            prominent: true,
          ),
          _HoverGlowButton(
            icon: items[2].icon,
            label: items[2].label,
            active: items[2].active,
            onTap: items[2].onTap,
          ),
          _HoverGlowButton(
            icon: items[3].icon,
            label: items[3].label,
            active: items[3].active,
            onTap: items[3].onTap,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildCollapsed(BuildContext context, List<_NavItem> items) {
    return Column(
      children: [
        const SizedBox(height: 8),
        ...items.sublist(0, 2).map(
          (item) => _CollapsedIcon(
            icon: item.icon,
            label: item.label,
            active: item.active,
            onTap: item.onTap,
          ),
        ),
        const SizedBox(height: 4),
        Divider(height: 1, color: context.cs.outlineVariant),
        Expanded(child: ChatHistoryList(collapsed: true)),
        Divider(height: 1, color: context.cs.outlineVariant),
        ...items.sublist(2).map(
          (item) => _CollapsedIcon(
            icon: item.icon,
            label: item.label,
            active: item.active,
            onTap: item.onTap,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _NavItem {
  final String id;
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({
    required this.id,
    required this.label,
    required this.icon,
    this.active = false,
    required this.onTap,
  });
}

/// Expanded sidebar button with mouse-tracking radial glow (ported from v-hover-glow).
class _HoverGlowButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  // prominent = true  → onSurface (white) when inactive, like desktop-chars-btn
  // prominent = false → onSurfaceVariant (gray) when inactive, like desktop-more-btn
  final bool prominent;

  const _HoverGlowButton({
    required this.icon,
    required this.label,
    this.active = false,
    required this.onTap,
    this.prominent = false,
  });

  @override
  State<_HoverGlowButton> createState() => _HoverGlowButtonState();
}

class _HoverGlowButtonState extends State<_HoverGlowButton> {
  Offset? _glowPos;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final primary = context.cs.primary;
    final inactive =
        widget.prominent ? context.cs.onSurface : context.cs.onSurfaceVariant;
    final color = widget.active ? primary : inactive;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (e) => setState(() {
        _glowPos = e.localPosition;
        _hovered = true;
      }),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRect(
          child: SizedBox(
            height: 40,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  color: _hovered
                      ? context.cs.onSurface.withValues(alpha: 0.05)
                      : Colors.transparent,
                ),
                AnimatedOpacity(
                  opacity: _hovered && _glowPos != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.ease,
                  child: CustomPaint(
                    painter: _glowPos != null
                        ? _RadialGlowPainter(
                            position: _glowPos!,
                            color: primary,
                          )
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(widget.icon, size: 18, color: color),
                      const SizedBox(width: 10),
                      Text(
                        widget.label,
                        style: (widget.prominent
                                ? Theme.of(context).textTheme.labelLarge
                                : Theme.of(context).textTheme.labelMedium)
                            ?.copyWith(color: color),
                      ),
                    ],
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

class _RadialGlowPainter extends CustomPainter {
  final Offset position;
  final Color color;

  const _RadialGlowPainter({required this.position, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final shader = ui.Gradient.radial(
      position,
      200.0,
      [
        color.withValues(alpha: 0.07),
        color.withValues(alpha: 0.04),
        color.withValues(alpha: 0.015),
        color.withValues(alpha: 0.0),
      ],
      [0.0, 0.38, 0.68, 1.0],
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_RadialGlowPainter old) =>
      old.position != position || old.color != color;
}

class _CollapsedIcon extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _CollapsedIcon({
    required this.icon,
    required this.label,
    this.active = false,
    required this.onTap,
  });

  @override
  State<_CollapsedIcon> createState() => _CollapsedIconState();
}

class _CollapsedIconState extends State<_CollapsedIcon> {
  Offset? _glowPos;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final primary = context.cs.primary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onHover: (e) => setState(() {
        _glowPos = e.localPosition;
        _hovered = true;
      }),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.label,
          preferBelow: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.active)
                      ColoredBox(color: primary.withValues(alpha: 0.15)),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      color: _hovered
                          ? context.cs.onSurface.withValues(alpha: 0.05)
                          : Colors.transparent,
                    ),
                    AnimatedOpacity(
                      opacity: _hovered && _glowPos != null ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.ease,
                      child: CustomPaint(
                        painter: _glowPos != null
                            ? _RadialGlowPainter(
                                position: _glowPos!,
                                color: primary,
                              )
                            : null,
                      ),
                    ),
                    Center(
                      child: Icon(
                        widget.icon,
                        size: 22,
                        color:
                            widget.active ? primary : context.cs.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
