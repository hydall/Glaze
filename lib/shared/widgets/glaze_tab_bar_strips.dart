import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_tab_bar.dart';
import 'swipe_tab_switcher.dart';

/// The two layouts behind [GlazeTabBar]. Kept apart from the widget that picks
/// between them so neither has to know the other exists.

// ── Pill ─────────────────────────────────────────────────────────────────────

/// How many tabs fit across the strip before it starts scrolling.
///
/// Fractional on purpose: past this many tabs the next one is left half-cut at
/// the edge, which says "there is more here" without shrinking every tab until
/// its label no longer fits. Two tabs still divide the strip exactly in half,
/// so the common case is unchanged.
const double _kVisibleTabs = 2.35;

/// Equal-width tabs in a bordered track, the active one filled with the accent.
class PillTabStrip extends StatefulWidget {
  final List<GlazeTabItem> tabs;
  final int activeIndex;
  final ValueChanged<int> onChanged;

  const PillTabStrip({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onChanged,
  });

  @override
  State<PillTabStrip> createState() => _PillTabStripState();
}

class _PillTabStripState extends State<PillTabStrip> {
  final ScrollController _scrollController = ScrollController();

  /// True once there are more tabs than fit, i.e. the strip scrolls.
  bool get _scrolls => widget.tabs.length > _kVisibleTabs;

  @override
  void didUpdateWidget(covariant PillTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex) _revealActiveTab();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Scrolls a clipped tab fully into view once it becomes active, so selecting
  /// the half-visible tab does not leave it half-visible.
  void _revealActiveTab() {
    if (!_scrolls) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final viewport = _scrollController.position.viewportDimension;
      final tabWidth = viewport / _kVisibleTabs;
      final target = (widget.activeIndex * tabWidth - (viewport - tabWidth) / 2)
          .clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    final activeIndex = widget.activeIndex;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final visible = tabs.length < _kVisibleTabs
            ? tabs.length.toDouble()
            : _kVisibleTabs;
        final tabWidth = viewportWidth / visible;
        final stripWidth = tabWidth * tabs.length;
        final radius = BorderRadius.circular(21);

        final strip = SizedBox(
          width: stripWidth,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                left: activeIndex * tabWidth,
                top: 3,
                bottom: 3,
                width: tabWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: GlassSurface(
                    borderRadius: BorderRadius.circular(18),
                    tint: context.cs.primary,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: Row(
                  children: List.generate(tabs.length, (index) {
                    final tab = tabs[index];
                    final isActive = index == activeIndex;
                    final color = isActive ? Colors.white : context.cs.primary;

                    return SizedBox(
                      width: tabWidth,
                      child: GestureDetector(
                        onTap: () => widget.onChanged(index),
                        behavior: HitTestBehavior.opaque,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(tab.icon, size: 18, color: color),
                            const SizedBox(width: 8),
                            // Flexible + ellipsis so a long localized label
                            // degrades instead of overflowing its tab.
                            Flexible(
                              child: Text(
                                tab.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: color,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        );

        // Swiping the strip flips the tab — but only while the strip does not
        // scroll, since otherwise the two gestures mean opposite things on the
        // same drag. Scrolling strips still switch tabs by swiping the body
        // (SwipeTabSwitcher) or by tapping.
        return SwipeTabSwitcher(
          enabled: !_scrolls,
          behavior: HitTestBehavior.opaque,
          index: activeIndex,
          length: tabs.length,
          onChanged: widget.onChanged,
          child: SizedBox(
            height: 42,
            child: GlassSurface(
              borderRadius: radius,
              tint: context.cs.surface,
              border: Border.all(
                color: context.cs.primary.withValues(alpha: 0.18),
              ),
              child: _scrolls
                  ? SingleChildScrollView(
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      child: strip,
                    )
                  : strip,
            ),
          ),
        );
      },
    );
  }
}

// ── Underline ────────────────────────────────────────────────────────────────

/// Tabs with no container: each label carries a rule that lights up in the
/// accent colour when its tab goes active.
///
/// Content-sized rather than equal-width — an underline has nothing to fill, so
/// stretching every tab to a share of the viewport would only push the labels
/// apart and put the strip back under whatever shares its top edge (in the chat
/// drawer, the panel's drag handle). Tabs shrink and ellipsize under pressure
/// instead of scrolling, so the strip never competes with a horizontal drag.
class UnderlineTabStrip extends StatelessWidget {
  final List<GlazeTabItem> tabs;
  final int activeIndex;
  final ValueChanged<int> onChanged;

  const UnderlineTabStrip({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwipeTabSwitcher(
      behavior: HitTestBehavior.opaque,
      index: activeIndex,
      length: tabs.length,
      onChanged: onChanged,
      child: Row(
        children: [
          for (var index = 0; index < tabs.length; index++) ...[
            if (index > 0) const SizedBox(width: 22),
            Flexible(
              child: _UnderlineTab(
                tab: tabs[index],
                active: index == activeIndex,
                onTap: () => onChanged(index),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UnderlineTab extends StatelessWidget {
  final GlazeTabItem tab;
  final bool active;
  final VoidCallback onTap;

  const _UnderlineTab({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    final idle = context.cs.onSurface.withValues(alpha: 0.45);
    final live = context.cs.onSurface;

    // One driver for the label, the icon and the rule, so the whole tab settles
    // as a single object. The rule fades in place rather than sliding between
    // tabs: with content-sized tabs a travelling rule has to measure every
    // tab's width each frame, which buys nothing on a two-tab strip.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: active ? 1 : 0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, t, _) {
        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            // Vertical padding only — it grows the tap target to a comfortable
            // height without moving the rule away from its label.
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Container(
              padding: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                // A bottom border rather than a stretched child: the border
                // takes the container's width, and the container takes the
                // row's, so the rule matches the label without an
                // IntrinsicWidth pass.
                border: Border(
                  bottom: BorderSide(
                    color: accent.withValues(alpha: t),
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    tab.icon,
                    size: 17,
                    color: Color.lerp(idle, accent, t),
                  ),
                  const SizedBox(width: 7),
                  // Flexible + ellipsis so a long localized label degrades
                  // instead of overflowing the header.
                  Flexible(
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color.lerp(idle, live, t),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
