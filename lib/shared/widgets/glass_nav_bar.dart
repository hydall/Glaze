import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/guides/guide_anchor.dart';
import '../shell/nav_height_provider.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'nav_tab_button.dart';

/// The shell's tab bar along the bottom of a phone held upright.
class GlassNavBar extends ConsumerStatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const GlassNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  ConsumerState<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends ConsumerState<GlassNavBar> {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      ref.read(navHeightProvider.notifier).state = box.size.height;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final isIosLikeTargetPlatform =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: _buttons(
          context,
          ref,
          currentIndex: widget.currentIndex,
          onTap: widget.onTap,
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
    );

    return Padding(
      key: _key,
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        (isIosLikeTargetPlatform ? 6 : 16) + bottomPad,
      ),
      child: GuideAnchor(
        id: GuideIds.navBar,
        child: GlassSurface(
          enableRipple: true,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.cs.outlineVariant),
          child: row,
        ),
      ),
    );
  }
}

/// Width of [GlassNavRail]'s glass pill.
const double kGlassNavRailWidth = 76;

/// Gap between [GlassNavRail]'s pill and the content beside it, and between
/// the pill and the screen edge.
const double kGlassNavRailMargin = 10;

/// How much horizontal room [GlassNavRail] takes from its edge — the left one
/// when [left], else the right — including the safe-area inset it sits in and
/// the gap between the pill and the content beside it.
double glassNavRailExtent(BuildContext context, {required bool left}) {
  final padding = MediaQuery.paddingOf(context);
  return (left ? padding.left : padding.right) +
      kGlassNavRailMargin * 2 +
      kGlassNavRailWidth;
}

/// The same tabs as [GlassNavBar], down one side of a phone held sideways,
/// where a bottom bar would eat a fifth of the short side.
///
/// The pill runs the full height of the screen inside the safe area, with the
/// tabs spread evenly along it, so each one is a large target under the thumb.
/// It sits inside its side's safe-area inset, so neither the pill nor the
/// content beside it ever lands under a notch or camera cutout.
class GlassNavRail extends ConsumerWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Along the left edge instead of the right.
  final bool left;

  const GlassNavRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.left = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final padding = MediaQuery.paddingOf(context);
    final buttons = _buttons(
      context,
      ref,
      currentIndex: currentIndex,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      expand: true,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        (left ? padding.left : 0) + kGlassNavRailMargin,
        padding.top + kGlassNavRailMargin,
        (left ? 0 : padding.right) + kGlassNavRailMargin,
        padding.bottom + kGlassNavRailMargin,
      ),
      child: GuideAnchor(
        id: GuideIds.navBar,
        child: GlassSurface(
          enableRipple: true,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.cs.outlineVariant),
          child: SizedBox(
            width: kGlassNavRailWidth,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final column = Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: buttons,
                  ),
                );
                // Normally the tabs spread over the whole height. On a screen
                // too short for them (large font scale on a small phone) the
                // column keeps its natural height and scrolls instead.
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: column,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

List<Widget> _buttons(
  BuildContext context,
  WidgetRef ref, {
  required int currentIndex,
  required ValueChanged<int> onTap,
  required EdgeInsets padding,
  bool expand = false,
}) => List.generate(kNavTabItems.length, (i) {
  final button = NavTabButton(
    item: kNavTabItems[i],
    isActive: i == currentIndex,
    padding: padding,
    onTap: () => handleNavTabTap(
      context,
      ref,
      index: i,
      currentIndex: currentIndex,
      onTap: onTap,
    ),
  );
  return GuideAnchor(
    id: GuideIds.navTab(i),
    child: expand ? SizedBox(width: double.infinity, child: button) : button,
  );
});
