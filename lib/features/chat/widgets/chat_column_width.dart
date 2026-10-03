import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../settings/app_settings_provider.dart';

/// Caps the chat column's width on desktop and lets it be dragged by its edges.
///
/// Vue drove this with `--chat-max-width` plus two absolutely-positioned
/// `.sidebar-drag-handle` elements at the column's edges (ChatView.vue) — the
/// port had neither, so messages stretched the full width of a 1080p monitor.
/// Dragging either edge resizes symmetrically and persists to settings; a width
/// of 0 means "fill the column" and hides the grips.
///
/// The [child] itself is not narrowed: the chat's WebView keeps the full width,
/// so its background is one surface edge to edge, and the messages keep to the
/// column inside the page. The child reads the cap from [ChatColumnScope] and
/// narrows what it lays over the WebView (the input bar, the buttons) to match.
class ChatColumnWidth extends ConsumerStatefulWidget {
  final Widget child;

  static const double minWidth = 400;
  static const double maxWidth = 1600;
  static const double handleWidth = 8;

  const ChatColumnWidth({super.key, required this.child});

  @override
  ConsumerState<ChatColumnWidth> createState() => _ChatColumnWidthState();
}

class _ChatColumnWidthState extends ConsumerState<ChatColumnWidth> {
  /// Live width during a drag; null when not dragging, so the settings value
  /// stays the single source of truth between gestures.
  double? _dragWidth;
  double _dragStart = 0;

  void _begin(double current) {
    _dragStart = current;
    setState(() => _dragWidth = current);
  }

  /// [sign] is +1 for the right grip (dragging right widens) and -1 for the
  /// left one; the column is centred, so each edge moves half the delta.
  void _update(double totalDx, int sign) {
    setState(() {
      _dragWidth = (_dragStart + sign * totalDx * 2).clamp(
        ChatColumnWidth.minWidth,
        ChatColumnWidth.maxWidth,
      );
    });
  }

  Future<void> _commit() async {
    final width = _dragWidth;
    setState(() => _dragWidth = null);
    if (width == null) return;
    final settings = ref.read(appSettingsProvider).value;
    if (settings == null) return;
    await ref
        .read(appSettingsProvider.notifier)
        .save(settings.copyWith(chatMaxWidth: width));
  }

  @override
  Widget build(BuildContext context) {
    final configured =
        ref.watch(appSettingsProvider.select((s) => s.value?.chatMaxWidth)) ??
        0;
    final width = _dragWidth ?? configured;
    final enabled = isDesktopLayout(context) && width > 0;

    // One shape whether or not the column is capped, so crossing the limit
    // (a window resize, the setting) never remounts the chat and its WebView.
    return LayoutBuilder(
      builder: (context, constraints) {
        // Nothing to cap — and nothing to drag — when the column is already
        // narrower than the limit.
        final capped = enabled && constraints.maxWidth > width;
        final gutter = capped ? (constraints.maxWidth - width) / 2 : 0.0;
        return Stack(
          children: [
            Positioned.fill(
              child: ChatColumnScope(
                gutter: gutter,
                columnWidth: capped ? width : 0,
                child: widget.child,
              ),
            ),
            if (capped) ...[
              _Grip(
                left: gutter - ChatColumnWidth.handleWidth / 2,
                onStart: () => _begin(width),
                onUpdate: (dx) => _update(dx, -1),
                onEnd: _commit,
              ),
              _Grip(
                left:
                    constraints.maxWidth -
                    gutter -
                    ChatColumnWidth.handleWidth / 2,
                onStart: () => _begin(width),
                onUpdate: (dx) => _update(dx, 1),
                onEnd: _commit,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The capped chat column handed down by [ChatColumnWidth]: [columnWidth] is
/// the width the messages keep to (0 when uncapped) and [gutter] the space left
/// on either side of it.
class ChatColumnScope extends InheritedWidget {
  final double gutter;
  final double columnWidth;

  const ChatColumnScope({
    super.key,
    required this.gutter,
    required this.columnWidth,
    required super.child,
  });

  /// The scope above [context]; null outside [ChatColumnWidth].
  static ChatColumnScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatColumnScope>();

  @override
  bool updateShouldNotify(ChatColumnScope oldWidget) =>
      gutter != oldWidget.gutter || columnWidth != oldWidget.columnWidth;
}

class _Grip extends StatefulWidget {
  final double left;
  final VoidCallback onStart;
  final void Function(double totalDx) onUpdate;
  final VoidCallback onEnd;

  const _Grip({
    required this.left,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  @override
  State<_Grip> createState() => _GripState();
}

class _GripState extends State<_Grip> {
  bool _lit = false;
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.left,
      top: 0,
      bottom: 0,
      width: ChatColumnWidth.handleWidth,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _lit = true),
        onExit: (_) => setState(() => _lit = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            _dx = 0;
            widget.onStart();
          },
          onHorizontalDragUpdate: (d) {
            _dx += d.delta.dx;
            widget.onUpdate(_dx);
          },
          onHorizontalDragEnd: (_) => widget.onEnd(),
          onHorizontalDragCancel: widget.onEnd,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            color: _lit
                ? Colors.white.withValues(alpha: 0.2)
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}
