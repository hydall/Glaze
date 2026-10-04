import 'package:flutter/material.dart';

import 'glaze_tab_bar_strips.dart';

class GlazeTabItem {
  final String label;
  final IconData icon;

  const GlazeTabItem({required this.label, required this.icon});
}

/// How a [GlazeTabBar] draws itself.
enum GlazeTabBarStyle {
  /// Equal-width tabs in a bordered track, the active one filled with the
  /// accent. The app default: it reads as a control at a glance, which is what
  /// a strip sitting inside a busy sheet or screen header needs.
  pill,

  /// No container at all — labels with an accent rule under the active one.
  /// For a strip that heads a surface it does not own, where a filled pill
  /// would outweigh the content it introduces.
  underline,
}

/// The Glaze segmented control. Tap, swipe-on-the-strip and (for [pill]) a
/// scrolling track once there are more tabs than fit.
class GlazeTabBar extends StatelessWidget {
  final List<GlazeTabItem> tabs;
  final int activeIndex;
  final ValueChanged<int> onChanged;
  final GlazeTabBarStyle style;

  const GlazeTabBar({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onChanged,
    this.style = GlazeTabBarStyle.pill,
  });

  @override
  Widget build(BuildContext context) {
    return switch (style) {
      GlazeTabBarStyle.pill => PillTabStrip(
        tabs: tabs,
        activeIndex: activeIndex,
        onChanged: onChanged,
      ),
      GlazeTabBarStyle.underline => UnderlineTabStrip(
        tabs: tabs,
        activeIndex: activeIndex,
        onChanged: onChanged,
      ),
    };
  }
}
