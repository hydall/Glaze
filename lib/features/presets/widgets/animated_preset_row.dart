import 'package:flutter/material.dart';

/// Entry and exit animation for one row of the Presets list.
///
/// A freshly mounted row fades and slides into place, so a preset that was just
/// created, cloned or imported glides in instead of popping. When [exiting]
/// turns true the row fades out while its height collapses: the screen sets the
/// flag *before* it commits the delete and waits [exitDuration], so the row has
/// already left the screen by the time the store drops it and the list closes
/// the gap without a jump.
///
/// Rows are keyed by their preset, so a state is only ever reused by the same
/// preset — that is what makes "mounted" a reliable stand-in for "appeared".
class AnimatedPresetRow extends StatefulWidget {
  /// Whether the row is playing its removal animation.
  final bool exiting;
  final Widget child;

  const AnimatedPresetRow({
    super.key,
    required this.exiting,
    required this.child,
  });

  /// How long the collapse takes. The screen waits exactly this long between
  /// marking a row as exiting and deleting the preset behind it.
  static const Duration exitDuration = Duration(milliseconds: 240);

  static const Duration entryDuration = Duration(milliseconds: 260);

  @override
  State<AnimatedPresetRow> createState() => _AnimatedPresetRowState();
}

class _AnimatedPresetRowState extends State<AnimatedPresetRow>
    with TickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: AnimatedPresetRow.entryDuration,
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: AnimatedPresetRow.exitDuration,
  );

  late final Animation<double> _entryFade = CurvedAnimation(
    parent: _entry,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _entrySlide =
      Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
        CurvedAnimation(parent: _entry, curve: Curves.easeOutCubic),
      );

  /// Drives both the fade and the height collapse on the way out: 1 → 0.
  late final Animation<double> _exitFactor =
      Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(parent: _exit, curve: Curves.easeIn),
      );

  @override
  void initState() {
    super.initState();
    _entry.forward();
    if (widget.exiting) _exit.value = 1;
  }

  @override
  void didUpdateWidget(covariant AnimatedPresetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting == oldWidget.exiting) return;
    if (widget.exiting) {
      _exit.forward();
    } else {
      // A row that stops exiting is not arriving — the delete was abandoned, or
      // this state was handed a different preset — so drop the collapse outright
      // instead of playing it backwards.
      _exit.value = 0;
    }
  }

  @override
  void dispose() {
    _entry.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // SizeTransition clips for us, so a collapsing row never paints outside the
    // shrinking slot.
    return SizeTransition(
      sizeFactor: _exitFactor,
      // Pinned to the top edge, so the row shrinks upwards into the gap the
      // rows below it are closing rather than towards its own centre.
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(
        opacity: _exitFactor,
        child: FadeTransition(
          opacity: _entryFade,
          child: SlideTransition(
            position: _entrySlide,
            // A row on its way out must not take taps meant for the row that
            // slides up into its place.
            child: IgnorePointer(
              ignoring: widget.exiting,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
