import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../core/debug/perf_debug.dart';

/// Gradient-masked blur and surface scrim across the top edge of [child].
///
/// Renders the same effect as `package:soft_edge_blur` (of which this is a
/// specialised fork — top edge only), but cheap enough for per-frame use:
///
///  * The upstream sampler layer never sets an engine layer, so it can't be
///    retained: ANY repaint anywhere in the app re-rasterised the entire
///    child subtree with `toImageSync`. This layer pushes an offset engine
///    layer, so when nothing changed the engine reuses it wholesale.
///  * When the layer IS re-added but the child's content hasn't changed
///    (modal slide-in/out, sheet drag — pure translations), a fingerprint of
///    the child layer tree detects it and the previously sampled picture is
///    reused instead of re-rasterising the subtree.
///  * [enabled] toggles the expensive blur without unmounting the child
///    subtree. The tint scrim remains visible so battery-saver mode still
///    keeps scrolling content legible beneath pinned chrome.
class TopEdgeBlur extends StatelessWidget {
  final Widget child;
  final bool enabled;

  /// Height (logical px) of the blurred strip along the top edge.
  final double height;
  final double sigma;
  final Color? tintColor;

  /// Fraction of [height] that stays fully blurred before the effect fades
  /// to transparent at the strip's bottom edge.
  final double fadeStart;

  const TopEdgeBlur({
    super.key,
    required this.child,
    required this.height,
    this.enabled = true,
    this.sigma = 24,
    this.tintColor,
    this.fadeStart = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          _TopEdgeBlurRenderWidget(
            enabled:
                enabled && !PerfDebug.noEdgeBlur && height > 0 && sigma > 0,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            height: height,
            sigma: sigma,
            // The tint is painted separately so it remains when blur is off.
            tintColor: null,
            fadeStart: fadeStart,
            child: child,
          ),
          if (tintColor case final tint?)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: height,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [tint, tint, tint.withValues(alpha: 0)],
                      stops: [0, fadeStart.clamp(0.0, 1.0), 1],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopEdgeBlurRenderWidget extends SingleChildRenderObjectWidget {
  final bool enabled;
  final double devicePixelRatio;
  final double height;
  final double sigma;
  final Color? tintColor;
  final double fadeStart;

  const _TopEdgeBlurRenderWidget({
    required this.enabled,
    required this.devicePixelRatio,
    required this.height,
    required this.sigma,
    required this.tintColor,
    required this.fadeStart,
    super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderTopEdgeBlur(
      enabled,
      devicePixelRatio,
      height,
      sigma,
      tintColor,
      fadeStart,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTopEdgeBlur renderObject,
  ) {
    renderObject
      ..enabled = enabled
      ..devicePixelRatio = devicePixelRatio
      ..height = height
      ..sigma = sigma
      ..tintColor = tintColor
      ..fadeStart = fadeStart;
  }
}

class _RenderTopEdgeBlur extends RenderProxyBox {
  _RenderTopEdgeBlur(
    this._enabled,
    this._devicePixelRatio,
    this._height,
    this._sigma,
    this._tintColor,
    this._fadeStart,
  );

  bool _enabled;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    markNeedsPaint();
    markNeedsCompositingBitsUpdate();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsCompositedLayerUpdate();
  }

  double _height;
  set height(double value) {
    if (value == _height) return;
    _height = value;
    markNeedsCompositedLayerUpdate();
  }

  double _sigma;
  set sigma(double value) {
    if (value == _sigma) return;
    _sigma = value;
    markNeedsCompositedLayerUpdate();
  }

  Color? _tintColor;
  set tintColor(Color? value) {
    if (value == _tintColor) return;
    _tintColor = value;
    markNeedsCompositedLayerUpdate();
  }

  double _fadeStart;
  set fadeStart(double value) {
    if (value == _fadeStart) return;
    _fadeStart = value;
    markNeedsCompositedLayerUpdate();
  }

  @override
  bool get isRepaintBoundary => alwaysNeedsCompositing;

  @override
  bool get alwaysNeedsCompositing => enabled;

  @override
  OffsetLayer updateCompositedLayer({
    required covariant _TopEdgeBlurLayer? oldLayer,
  }) {
    final layer = oldLayer ?? _TopEdgeBlurLayer();
    layer
      ..contentSize = size
      ..devicePixelRatio = _devicePixelRatio
      ..stripHeight = _height
      ..sigma = _sigma
      ..tintColor = _tintColor
      ..fadeStart = _fadeStart;
    return layer;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    assert(!_enabled || offset == Offset.zero);
    super.paint(context, offset);
  }
}

class _TopEdgeBlurLayer extends OffsetLayer {
  ui.Picture? _picture;
  List<Object?>? _fingerprint;

  void _invalidate() {
    _picture?.dispose();
    _picture = null;
    _fingerprint = null;
    markNeedsAddToScene();
  }

  Size _contentSize = Size.zero;
  set contentSize(Size value) {
    if (value == _contentSize) return;
    _contentSize = value;
    _invalidate();
  }

  double _devicePixelRatio = 1.0;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _invalidate();
  }

  double _stripHeight = 0;
  set stripHeight(double value) {
    if (value == _stripHeight) return;
    _stripHeight = value;
    _invalidate();
  }

  double _sigma = 24;
  set sigma(double value) {
    if (value == _sigma) return;
    _sigma = value;
    _invalidate();
  }

  Color? _tintColor;
  set tintColor(Color? value) {
    if (value == _tintColor) return;
    _tintColor = value;
    _invalidate();
  }

  double _fadeStart = 0.5;
  set fadeStart(double value) {
    if (value == _fadeStart) return;
    _fadeStart = value;
    _invalidate();
  }

  @override
  void dispose() {
    _picture?.dispose();
    _picture = null;
    _fingerprint = null;
    super.dispose();
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (_contentSize.isEmpty) return;
    final fingerprint = _computeFingerprint();
    if (_picture == null ||
        fingerprint == null ||
        !_fingerprintMatches(fingerprint)) {
      _fingerprint = fingerprint;
      _resample();
    }
    // Push a real engine layer (unlike the upstream package) so retained
    // rendering can skip this subtree entirely when nothing changed.
    engineLayer = builder.pushOffset(
      offset.dx,
      offset.dy,
      oldLayer: engineLayer as ui.OffsetEngineLayer?,
    );
    builder.addPicture(Offset.zero, _picture!);
    builder.pop();
  }

  void _resample() {
    final image = _buildChildScene(_contentSize, _devicePixelRatio);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    try {
      _draw(image, canvas);
    } finally {
      image.dispose();
    }
    _picture?.dispose();
    _picture = recorder.endRecording();
  }

  ui.Image _buildChildScene(Size bounds, double pixelRatio) {
    final sceneBuilder = ui.SceneBuilder();
    final transform = Matrix4.diagonal3Values(pixelRatio, pixelRatio, 1);
    sceneBuilder.pushTransform(transform.storage);
    addChildrenToScene(sceneBuilder);
    sceneBuilder.pop();
    return sceneBuilder.build().toImageSync(
      (pixelRatio * bounds.width).ceil(),
      (pixelRatio * bounds.height).ceil(),
    );
  }

  /// Paints the sampled child plus the blurred/tinted/gradient-masked strip.
  /// The drawing math mirrors soft_edge_blur 0.1.3 exactly for visual parity.
  void _draw(ui.Image image, Canvas canvas) {
    canvas.scale(1 / _devicePixelRatio);
    canvas.drawImage(image, Offset.zero, Paint());

    final strip = _stripHeight.clamp(0.0, _contentSize.height);
    if (strip <= 0) return;
    final rect = Rect.fromLTRB(
      0,
      0,
      _contentSize.width * _devicePixelRatio,
      strip * _devicePixelRatio,
    );

    final gradient = ui.Gradient.linear(
      rect.topCenter,
      rect.bottomCenter,
      const [Color(0xFF000000), Color(0x00000000)],
      [_fadeStart.clamp(0.0, 1.0), 1.0],
    );

    canvas.saveLayer(rect, Paint());
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: _sigma,
          sigmaY: _sigma,
          tileMode: TileMode.clamp,
        ),
    );
    final tint = _tintColor;
    if (tint != null) {
      canvas.drawRect(rect, Paint()..color = tint);
    }
    canvas.drawRect(
      rect,
      Paint()
        ..shader = gradient
        ..blendMode = BlendMode.dstIn,
    );
    canvas.restore();
  }

  /// Snapshot of the child layer tree's identity/mutable-in-place state.
  /// If two consecutive scene builds produce equal fingerprints the child's
  /// pixels are unchanged (only this layer's own offset/props may differ) and
  /// the cached sample can be reused. Returns null when the subtree contains
  /// layers whose content changes out-of-band (textures, platform views,
  /// leader-following), which forces a resample every frame.
  List<Object?>? _computeFingerprint() {
    final out = <Object?>[];
    return _collect(firstChild, out) ? out : null;
  }

  bool _collect(Layer? layer, List<Object?> out) {
    var node = layer;
    while (node != null) {
      if (node is TextureLayer ||
          node is PlatformViewLayer ||
          node is FollowerLayer) {
        return false;
      }
      out.add(node);
      if (node is PictureLayer) {
        out.add(node.picture);
      } else if (node is OffsetLayer) {
        // Mutated in place during scrolls without any repaint.
        out.add(node.offset);
      }
      if (node is OpacityLayer) {
        // RenderAnimatedOpacity mutates alpha via composited-layer updates
        // without creating new picture layers.
        out.add(node.alpha);
      } else if (node is TransformLayer) {
        out.add(node.transform?.clone());
      } else if (node is ImageFilterLayer) {
        out.add(node.imageFilter);
      } else if (node is BackdropFilterLayer) {
        out.add(node.filter);
      }
      if (node is ContainerLayer && !_collect(node.firstChild, out)) {
        return false;
      }
      node = node.nextSibling;
    }
    return true;
  }

  bool _fingerprintMatches(List<Object?> fingerprint) {
    final prev = _fingerprint;
    if (prev == null || prev.length != fingerprint.length) return false;
    for (var i = 0; i < prev.length; i++) {
      if (prev[i] != fingerprint[i]) return false;
    }
    return true;
  }
}
