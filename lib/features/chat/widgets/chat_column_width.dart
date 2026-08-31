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

    if (!isDesktopLayout(context) || width <= 0) return widget.child;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Nothing to cap — and nothing to drag — when the column is already
        // narrower than the limit.
        if (constraints.maxWidth <= width) return widget.child;
        final gutter = (constraints.maxWidth - width) / 2;
        return Stack(
          children: [
            Positioned(
              left: gutter,
              right: gutter,
              top: 0,
              bottom: 0,
              child: widget.child,
            ),
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
        );
      },
    );
  }
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
