import 'package:flutter/widgets.dart';

/// An [Overlay] spanning the whole window, above the router's own.
///
/// Widgets drawn outside the navigator — the app's title bar, the glossary
/// window — still need one: tooltips, a text field's selection handles and
/// menus all open into the nearest [Overlay], and without one they render as
/// "No Overlay widget found" errors. Inside the navigator the navigator's own
/// overlay stays the nearest, so nothing there changes.
class RootOverlay extends StatefulWidget {
  final Widget child;

  const RootOverlay({super.key, required this.child});

  @override
  State<RootOverlay> createState() => _RootOverlayState();
}

class _RootOverlayState extends State<RootOverlay> {
  // Reads `widget` when it builds, so it always shows the current child.
  late final OverlayEntry _entry = OverlayEntry(builder: (_) => widget.child);

  @override
  void didUpdateWidget(RootOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
