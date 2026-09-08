import 'package:flutter/widgets.dart';

import '../bridge/chat_overlay_blur_region.dart';

/// Collects the on-screen rects of glass widgets that overlay the chat
/// WebView (input pill, circle buttons, ...) so `_ChatBody` can sync them
/// to the WebView as [ChatOverlayBlurRegion]s.
///
/// Registration only stores the element's [BuildContext]; the actual
/// measurement happens in [measure], driven by the owner in a post-frame
/// callback (the owner rebuilds on every layout-moving change: keyboard,
/// drawer animation, input growth). Listeners fire when the set of tracked
/// widgets changes (e.g. the input bar swaps to search/selection mode
/// without the owner rebuilding), so the owner can schedule a re-measure.
class ChatBlurRegionRegistry extends ChangeNotifier {
  final Map<String, _BlurRegionEntry> _entries = {};

  void register(String id, BuildContext context, double radius) {
    final existing = _entries[id];
    if (existing != null &&
        existing.context == context &&
        existing.radius == radius) {
      return;
    }
    _entries[id] = _BlurRegionEntry(context, radius);
    notifyListeners();
  }

  void unregister(String id, BuildContext context) {
    // Only remove our own registration: on a same-frame remount the new
    // tracker may have registered before the old one's dispose runs.
    if (_entries[id]?.context != context) return;
    _entries.remove(id);
    notifyListeners();
  }

  /// Measures every tracked widget relative to [reference] (the WebView's
  /// render box). Unmounted / not-yet-laid-out entries are skipped. The
  /// result is sorted by id so identical geometry always compares equal.
  List<ChatOverlayBlurRegion> measure(RenderBox reference) {
    final origin = reference.localToGlobal(Offset.zero);
    final out = <ChatOverlayBlurRegion>[];
    for (final entry in _entries.entries) {
      final ctx = entry.value.context;
      if (!ctx.mounted) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final topLeft = box.localToGlobal(Offset.zero) - origin;
      out.add(
        ChatOverlayBlurRegion(
          id: entry.key,
          rect: topLeft & box.size,
          radius: entry.value.radius,
        ),
      );
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }
}

class _BlurRegionEntry {
  const _BlurRegionEntry(this.context, this.radius);
  final BuildContext context;
  final double radius;
}

/// Provides a [ChatBlurRegionRegistry] to descendant [BlurRegionTracker]s.
class ChatBlurRegionScope extends InheritedWidget {
  const ChatBlurRegionScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final ChatBlurRegionRegistry registry;

  static ChatBlurRegionRegistry? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ChatBlurRegionScope>()
      ?.registry;

  @override
  bool updateShouldNotify(ChatBlurRegionScope oldWidget) =>
      registry != oldWidget.registry;
}

/// Marks its child as a glass element whose backdrop blur must be mirrored
/// into the chat WebView. No-op when no [ChatBlurRegionScope] is present,
/// so wrapped widgets stay reusable outside the chat screen.
class BlurRegionTracker extends StatefulWidget {
  const BlurRegionTracker({
    super.key,
    required this.id,
    required this.radius,
    required this.child,
  });

  final String id;
  final double radius;
  final Widget child;

  @override
  State<BlurRegionTracker> createState() => _BlurRegionTrackerState();
}

class _BlurRegionTrackerState extends State<BlurRegionTracker> {
  ChatBlurRegionRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = ChatBlurRegionScope.maybeOf(context);
    if (registry != _registry) {
      _registry?.unregister(widget.id, context);
      _registry = registry;
    }
    _registry?.register(widget.id, context, widget.radius);
  }

  @override
  void didUpdateWidget(BlurRegionTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _registry?.unregister(oldWidget.id, context);
    }
    _registry?.register(widget.id, context, widget.radius);
  }

  @override
  void dispose() {
    _registry?.unregister(widget.id, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
