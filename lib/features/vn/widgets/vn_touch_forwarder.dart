import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Hands every touch over [child] to the engine itself, instead of letting the
/// platform view forward it.
///
/// Android's platform-view forwarding offsets the whole MotionEvent by the
/// first pointer in Flutter's order minus the first pointer in Android's, and
/// the two orders differ as soon as one finger lifts and lands again while
/// another is down: every coordinate in the WebView then jumps by the distance
/// between the fingers, which flung the camera. Here the WebView gets no
/// touches at all and the engine reads them from [onEvents] in local logical
/// pixels, which are CSS pixels in the page.
///
/// Events are batched while a call into the page is still out, so a fast drag
/// cannot queue more calls than the page can take.
class VnTouchForwarder extends StatefulWidget {
  const VnTouchForwarder({
    super.key,
    required this.onEvents,
    required this.child,
  });

  /// Sends `[kind, pointer, x, y]` events (kind `d`, `m`, `u` or `c`) to the
  /// page and completes when the page has taken them.
  final Future<void> Function(List<List<Object>> events) onEvents;

  final Widget child;

  @override
  State<VnTouchForwarder> createState() => _VnTouchForwarderState();
}

class _VnTouchForwarderState extends State<VnTouchForwarder> {
  final List<List<Object>> _pending = [];
  bool _inFlight = false;

  void _add(String kind, PointerEvent e) {
    final p = e.localPosition;
    final event = <Object>[
      kind,
      e.pointer,
      double.parse(p.dx.toStringAsFixed(1)),
      double.parse(p.dy.toStringAsFixed(1)),
    ];
    // Only the latest move of a pointer matters: the engine reads deltas
    // from the last position it saw.
    if (kind == 'm' &&
        _pending.isNotEmpty &&
        _pending.last[0] == 'm' &&
        _pending.last[1] == e.pointer) {
      _pending[_pending.length - 1] = event;
    } else {
      _pending.add(event);
    }
    unawaited(_flush());
  }

  Future<void> _flush() async {
    if (_inFlight || _pending.isEmpty) return;
    _inFlight = true;
    final batch = List<List<Object>>.of(_pending);
    _pending.clear();
    try {
      await widget.onEvents(batch);
    } catch (e) {
      debugPrint('[VN3D] input failed: $e');
    } finally {
      _inFlight = false;
    }
    if (mounted) unawaited(_flush());
  }

  @override
  Widget build(BuildContext context) {
    // The eager recognizer claims every pointer, so the route's back swipe and
    // the shell's drags never take a walking finger.
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _add('d', e),
        onPointerMove: (e) => _add('m', e),
        onPointerUp: (e) => _add('u', e),
        onPointerCancel: (e) => _add('c', e),
        child: IgnorePointer(child: widget.child),
      ),
    );
  }
}
