import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';

/// Scrolls itself into view when it mounts, then flashes its child twice with
/// the accent colour.
///
/// Used to point at the row a More-tab search hit landed on: the deep link
/// rebuilds the settings screen, this makes it obvious which of the twenty
/// switches on it was the one being looked for. Doing the scroll from here —
/// rather than from the screen, through a [GlobalKey] — means it happens the
/// moment the row actually exists, however many frames the settings load takes.
class SettingsHighlight extends StatefulWidget {
  final Widget child;

  const SettingsHighlight({super.key, required this.child});

  @override
  State<SettingsHighlight> createState() => _SettingsHighlightState();
}

class _SettingsHighlightState extends State<SettingsHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 1200),
    vsync: this,
  );

  late final Animation<double> _alpha = TweenSequence<double>([
    TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 1.0), weight: 25),
    TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 0.0), weight: 25),
    TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 1.0), weight: 25),
    TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 0.0), weight: 25),
  ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_reveal()));
  }

  Future<void> _reveal() async {
    if (!mounted) return;
    await Scrollable.ensureVisible(
      context,
      alignment: 0.35,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
    if (mounted) unawaited(_controller.forward());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _alpha,
      child: widget.child,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: _alpha.value * 0.18),
        ),
        child: child,
      ),
    );
  }
}
