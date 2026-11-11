import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/platform/haptics.dart';
import '../../core/state/character_provider.dart';
import '../shell/nav_retap_provider.dart';
import '../theme/app_colors.dart';
import 'glaze_toast.dart';

/// The shell's four tabs and their tap handling, shared by the bottom
/// [GlassNavBar] (phone upright) and the side [GlassNavRail] (phone sideways).

String _iconSvg(String path) =>
    '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="$path"/></svg>';

class NavTabItem {
  final String labelKey;
  final String svgPath;

  const NavTabItem({required this.labelKey, required this.svgPath});
}

const kNavTabItems = [
  NavTabItem(
    labelKey: 'tab_dialogs',
    svgPath:
        'M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z',
  ),
  NavTabItem(
    labelKey: 'tab_characters',
    svgPath:
        'M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z',
  ),
  NavTabItem(
    labelKey: 'tab_tools',
    svgPath:
        'm21.71 20.29l-1.42 1.42a1 1 0 0 1-1.41 0L7 9.85A3.81 3.81 0 0 1 6 10a4 4 0 0 1-3.78-5.3l2.54 2.54l.53-.53l1.42-1.42l.53-.53L4.7 2.22A4 4 0 0 1 10 6a3.81 3.81 0 0 1-.15 1l11.86 11.88a1 1 0 0 1 0 1.41M2.29 18.88a1 1 0 0 0 0 1.41l1.42 1.42a1 1 0 0 0 1.41 0l5.47-5.46l-2.83-2.83M20 2l-4 2v2l-2.17 2.17l2 2L18 8h2l2-4Z',
  ),
  NavTabItem(
    labelKey: 'tab_more',
    svgPath: 'M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z',
  ),
];

/// Index of the Characters tab in [kNavTabItems]. Tapping it
/// [kRevealHiddenTapCount] times within [kRevealHiddenTapWindow] reveals hidden
/// characters (secret gesture).
const int _kCharactersTabIndex = 1;

/// What a tap on tab [index] does, wherever the tab is drawn: haptics, the
/// re-tap "back to top", the hidden-characters gesture, then [onTap].
void handleNavTabTap(
  BuildContext context,
  WidgetRef ref, {
  required int index,
  required int currentIndex,
  required ValueChanged<int> onTap,
}) {
  if (index != currentIndex) {
    Haptics.selectionClick();
  } else {
    // Re-tap on the already-active tab: ask that branch's screen to return to
    // the top of its main view (sub-routes are popped by the shell's
    // goBranch(initialLocation: true)).
    ref.read(navReTapProvider.notifier).reTap(index);
  }
  if (index == _kCharactersTabIndex) {
    final revealed = ref
        .read(revealHiddenCharactersProvider.notifier)
        .registerCharactersTabTap();
    if (revealed != null && context.mounted) {
      Haptics.heavyImpact();
      GlazeToast.show(
        context,
        revealed ? 'hidden_chars_revealed'.tr() : 'hidden_chars_hidden'.tr(),
      );
    }
  }
  onTap(index);
}

/// One tab: its icon over its label, tinted towards the accent when active.
class NavTabButton extends StatelessWidget {
  final NavTabItem item;
  final bool isActive;
  final VoidCallback onTap;

  /// Space around the icon and label, which is also the tab's hit area.
  final EdgeInsets padding;

  const NavTabButton({
    super.key,
    required this.item,
    required this.isActive,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  Widget build(BuildContext context) {
    final target = isActive ? 1.0 : 0.0;
    final label = item.labelKey.tr();
    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: target, end: target),
          duration: const Duration(milliseconds: 125),
          curve: Curves.easeInOut,
          builder: (context, t, _) {
            final color = Color.lerp(
              context.cs.secondary,
              _effectiveActive(context),
              t,
            )!;
            return Padding(
              padding: padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.string(
                    _iconSvg(item.svgPath),
                    width: 28,
                    height: 28,
                    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      // The Inter variable font is loaded at runtime via
                      // loadFontFromList, which ignores `fontWeight` — the
                      // weight axis must be driven explicitly via
                      // `fontVariations`.
                      fontVariations: const [FontVariation('wght', 500)],
                      color: color,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The accent, pushed lighter or darker when it would otherwise sit on the
  /// same side of the surface's luminance as the inactive colour and fail to
  /// stand out from it.
  Color _effectiveActive(BuildContext context) {
    final inactive = context.cs.secondary;
    final active = context.colors.accent;
    final surfaceLum = context.cs.surface.computeLuminance();
    final sameSide =
        (active.computeLuminance() > surfaceLum) ==
        (inactive.computeLuminance() > surfaceLum);
    if (sameSide) return active;
    final hsl = HSLColor.fromColor(active);
    final shift = surfaceLum < 0.5 ? 0.3 : -0.3;
    return hsl.withLightness((hsl.lightness + shift).clamp(0.0, 1.0)).toColor();
  }
}
