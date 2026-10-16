import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the plugins of one chat draw over its WebView. Plugin panels are
/// laid out for the whole screen and expect nothing on top of them. Where the
/// panels live in the plugin layer over the app's controls, only these areas
/// of the layer take taps ([PluginHolesHitArea]); elsewhere the app's own
/// controls over the page leave them out ([PluginHolesCutter]): not drawn
/// there, and taps there reach the page.
class PluginHoles extends ChangeNotifier {
  static const int _maxRects = 256;

  List<Rect> _rects = const [];

  /// The page the rects are measured in: the box of the WebView the panels
  /// are in.
  BuildContext? Function()? page;

  /// In WebView page pixels.
  List<Rect> get rects => _rects;

  /// Takes what the page reports, `[[x, y, w, h], …]`.
  void update(List<Object?> raw) {
    final next = <Rect>[];
    for (final r in raw.take(_maxRects)) {
      if (r is! List || r.length != 4) continue;
      final v = [for (final x in r) x is num ? x.toDouble() : double.nan];
      if (v.any((x) => !x.isFinite) || v[2] <= 0 || v[3] <= 0) continue;
      next.add(Rect.fromLTWH(v[0], v[1], v[2], v[3]));
    }
    if (listEquals(next, _rects)) return;
    _rects = List.unmodifiable(next);
    notifyListeners();
  }

  void clear() => update(const []);

  /// [rects] in global coordinates; empty while the page is not laid out.
  List<Rect> globalRects() {
    final page = this.page?.call()?.findRenderObject();
    if (_rects.isEmpty ||
        page is! RenderBox ||
        !page.attached ||
        !page.hasSize) {
      return const [];
    }
    final origin = page.localToGlobal(Offset.zero);
    return [for (final r in _rects) r.shift(origin)];
  }
}

/// [holes] in [box]'s coordinates, only those that touch it.
List<Rect> _holesIn(RenderBox box, PluginHoles holes) {
  final global = holes.globalRects();
  if (global.isEmpty || !box.hasSize) return const [];
  final origin = box.localToGlobal(Offset.zero);
  final bounds = Offset.zero & box.size;
  return [
    for (final r in global)
      if (r.shift(-origin).overlaps(bounds)) r.shift(-origin),
  ];
}

final pluginHolesProvider = Provider.family<PluginHoles, String>((ref, charId) {
  final holes = PluginHoles();
  ref.onDispose(holes.dispose);
  return holes;
});

/// Leaves the areas plugins draw in out of [child]: it is not painted there
/// and does not take taps there. Unless not [enabled]: where the panels are
/// in the plugin layer, they draw over [child] whole.
class PluginHolesCutter extends SingleChildRenderObjectWidget {
  const PluginHolesCutter({
    super.key,
    required this.holes,
    this.enabled = true,
    super.child,
  });

  final PluginHoles holes;
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPluginHolesCutter(holes, enabled: enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderPluginHolesCutter renderObject,
  ) {
    renderObject
      ..holes = holes
      ..enabled = enabled;
  }
}

class RenderPluginHolesCutter extends RenderProxyBox {
  RenderPluginHolesCutter(this._holes, {bool enabled = true})
    : _enabled = enabled;

  bool _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    markNeedsPaint();
  }

  PluginHoles _holes;
  set holes(PluginHoles value) {
    if (identical(value, _holes)) return;
    if (attached) {
      _holes.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _holes = value;
    markNeedsPaint();
  }

  final LayerHandle<ClipPathLayer> _clip = LayerHandle<ClipPathLayer>();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _holes.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _holes.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  List<Rect> _localHoles() => _enabled ? _holesIn(this, _holes) : const [];

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    for (final r in _localHoles()) {
      if (r.contains(position)) return false;
    }
    return super.hitTest(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final holes = _localHoles();
    if (holes.isEmpty) {
      _clip.layer = null;
      super.paint(context, offset);
      return;
    }
    var cut = Path();
    for (final r in holes) {
      cut = Path.combine(PathOperation.union, cut, Path()..addRect(r));
    }
    final bounds = Offset.zero & size;
    final keep = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      cut,
    );
    _clip.layer = context.pushClipPath(
      needsCompositing,
      offset,
      bounds,
      keep,
      super.paint,
      oldLayer: _clip.layer,
    );
  }
}

/// Takes taps only in the areas plugins draw in: anywhere else they go to
/// what is under [child], the plugin layer.
class PluginHolesHitArea extends SingleChildRenderObjectWidget {
  const PluginHolesHitArea({super.key, required this.holes, super.child});

  final PluginHoles holes;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPluginHolesHitArea(holes);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderPluginHolesHitArea renderObject,
  ) {
    renderObject.holes = holes;
  }
}

class RenderPluginHolesHitArea extends RenderProxyBox {
  RenderPluginHolesHitArea(this.holes);

  PluginHoles holes;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    for (final r in _holesIn(this, holes)) {
      if (r.contains(position)) {
        return super.hitTest(result, position: position);
      }
    }
    return false;
  }
}
