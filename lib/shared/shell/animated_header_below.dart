import 'package:flutter/material.dart';

/// Animates the header's `below` slot (e.g. the character list's segmented tab
/// bar) in and out when a screen switch — or a same-screen claim like the
/// character list toggling in and out of a folder — adds or removes it.
///
/// Kept deliberately decoupled from the header's own app-bar cross-fade: when
/// navigating between a screen whose header carries a segmented control and one
/// that does not, the control gets a dedicated vertical slide of its own rather
/// than plain-fading with the rest of the header. Appearing slides down into
/// place from above the app bar; disappearing rides back up and fades, mirroring
/// the header's hide-on-scroll direction convention.
class AnimatedHeaderBelow extends StatelessWidget {
  final Widget? below;
  const AnimatedHeaderBelow({super.key, required this.below});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.topCenter,
          children: [...previousChildren, ?currentChild],
        ),
        transitionBuilder: (child, animation) => ClipRect(
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
        ),
        child: below == null
            ? const SizedBox.shrink(key: ValueKey('shell-header-below-empty'))
            : KeyedSubtree(
                key: const ValueKey('shell-header-below-content'),
                child: below!,
              ),
      ),
    );
  }
}
