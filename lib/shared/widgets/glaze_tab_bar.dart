import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'swipe_tab_switcher.dart';

class GlazeTabItem {
  final String label;
  final IconData icon;

  const GlazeTabItem({required this.label, required this.icon});
}

/// How many tabs fit across the strip before it starts scrolling.
///
/// Fractional on purpose: past this many tabs the next one is left half-cut at
/// the edge, which says "there is more here" without shrinking every tab until
/// its label no longer fits. Two tabs still divide the strip exactly in half,
/// so the common case is unchanged.
const double _kVisibleTabs = 2.35;

class GlazeTabBar extends StatefulWidget {
  final List<GlazeTabItem> tabs;
  final int activeIndex;
  final ValueChanged<int> onChanged;

  const GlazeTabBar({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onChanged,
  });

  @override
  State<GlazeTabBar> createState() => _GlazeTabBarState();
}

class _GlazeTabBarState extends State<GlazeTabBar> {
  // Accumulated horizontal travel for a swipe performed directly on the strip.
  double _swipeDistance = 0;

  final ScrollController _scrollController = ScrollController();

  /// True once there are more tabs than fit, i.e. the strip scrolls.
  bool get _scrolls => widget.tabs.length > _kVisibleTabs;

  @override
  void didUpdateWidget(covariant GlazeTabBar oldWidget) {
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

  void _handleSwipeEnd(double velocity) {
    final target = resolveSwipeTarget(
      index: widget.activeIndex,
      length: widget.tabs.length,
      distance: _swipeDistance,
      velocity: velocity,
    );
    if (target != null) widget.onChanged(target);
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

        final body = SizedBox(
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
        );

        // Swiping the strip flips the tab — but only while the strip does not
        // scroll, since otherwise the two gestures mean opposite things on the
        // same drag. Scrolling strips still switch tabs by swiping the body
        // (SwipeTabSwitcher) or by tapping.
        if (_scrolls) return body;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _swipeDistance = 0,
          onHorizontalDragUpdate: (d) => _swipeDistance += d.delta.dx,
          onHorizontalDragEnd: (d) => _handleSwipeEnd(d.primaryVelocity ?? 0),
          child: body,
        );
      },
    );
  }
}
