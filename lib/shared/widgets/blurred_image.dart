import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/debug/perf_debug.dart';
import 'baked_blur.dart';

/// Full-bleed background image (`BoxFit.cover`) painted through a Gaussian
/// blur — with the blur **baked once** instead of re-run on every frame.
///
/// The obvious spelling, `ImageFiltered(imageFilter: blur, child: Image(...))`,
/// is a per-frame cost: an image filter layer is re-applied on every composite,
/// and under Impeller there is no raster cache to fall back on, so a
/// screen-sized sigma-30 blur is recomputed on the raster thread for every
/// frame of every scroll. On the app background — which is a still image that
/// only changes when the theme preset does — that is pure waste.
///
/// [BlurredImage] instead renders the covered image into an offscreen once,
/// blurs it there, and keeps the result as a `ui.Image` that later frames draw
/// 1:1. The offscreen is built exactly the way the widget layer would have
/// been (same `BoxFit.cover` geometry, same `saveLayer` bounds, same
/// [ui.TileMode.clamp] at the edges, sigma scaled into device pixels), so the
/// pixels are the ones [ImageFiltered] would have produced.
///
/// Baked images are shared app-wide by (provider, sigma, pixel size), so the
/// per-screen [GlazeBackground] copies all draw the same texture, and a screen
/// that is pushed and popped does not re-blur.
class BlurredImage extends StatefulWidget {
  /// Source image. Must implement value equality (all of Flutter's built-in
  /// providers do) — it is part of the bake cache key.
  final ImageProvider image;

  /// Blur sigma in logical pixels, matching [ui.ImageFilter.blur]. At zero (or
  /// with `NO_BG_BLUR` set) the image is drawn straight, with no offscreen.
  final double sigma;

  const BlurredImage({super.key, required this.image, required this.sigma});

  @override
  State<BlurredImage> createState() => _BlurredImageState();
}

class _BlurredImageState extends State<BlurredImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// Owned clone of the decoded source. Cloned so that an eviction from
  /// Flutter's image cache cannot dispose the pixels out from under a bake.
  ui.Image? _source;

  /// Owned clone of the cached bake currently being painted.
  ui.Image? _baked;
  BakedBlurKey? _bakedKey;

  /// Key the pending post-frame bake was scheduled for, so a resize storm
  /// queues one bake rather than one per frame.
  BakedBlurKey? _scheduledKey;

  Size _size = Size.zero;
  double _devicePixelRatio = 1.0;

  bool get _blurred => widget.sigma > 0 && !PerfDebug.noBgBlur;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveSource();
  }

  @override
  void didUpdateWidget(covariant BlurredImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-resolve on a sigma change too. A surface that started with no blur
    // (sigma 0, e.g. Battery Saver ON when the app booted) never resolved a
    // source, so switching the blur on would otherwise have nothing to bake and
    // the background would stay blank until the image itself changed.
    if (widget.image != oldWidget.image || widget.sigma != oldWidget.sigma) {
      _resolveSource();
    }
  }

  @override
  void dispose() {
    _detachStream();
    _source?.dispose();
    _baked?.dispose();
    super.dispose();
  }

  void _detachStream() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _resolveSource() {
    if (!_blurred) {
      // The plain [Image] below resolves the provider itself.
      _detachStream();
      return;
    }
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _detachStream();
    final listener = ImageStreamListener(_onSourceReady, onError: _onError);
    _listener = listener;
    _stream = stream..addListener(listener);
  }

  void _onSourceReady(ImageInfo info, bool synchronousCall) {
    final image = info.image.clone();
    info.dispose();
    if (!mounted) {
      image.dispose();
      return;
    }
    _source?.dispose();
    _source = image;
    _bakeIfNeeded();
  }

  void _onError(Object error, StackTrace? stack) {
    // An undecodable background is not worth a crash — the base colour and the
    // dim overlay behind this widget still render a usable screen.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'glaze',
        context: ErrorDescription('resolving a blurred background image'),
        silent: true,
      ),
    );
  }

  /// Bakes now if the current geometry has no cached result yet. Safe to call
  /// from `build`: the actual work is deferred to a post-frame callback, and
  /// repeated calls for the same key collapse into one.
  void _bakeIfNeeded() {
    if (!_blurred || _source == null || _size.isEmpty || !_size.isFinite) {
      return;
    }
    final key = BakedBlurKey(
      provider: widget.image,
      sigma: widget.sigma,
      dim: 0,
      size: _size,
      devicePixelRatio: _devicePixelRatio,
    );
    if (key == _bakedKey || key == _scheduledKey) return;
    _scheduledKey = key;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduledKey != key) return;
      _scheduledKey = null;
      _bakeNow(key);
    });
    // A post-frame callback runs at the end of the *next* frame, and nothing
    // here schedules one: the decode that gets us here finishes outside the
    // frame loop, and on a still screen no other frame may be coming. Ask for
    // one explicitly so the bake cannot sit and wait for unrelated work.
    SchedulerBinding.instance.scheduleFrame();
  }

  void _bakeNow(BakedBlurKey key) {
    final source = _source;
    if (source == null) return;
    final baked = BakedBlurCache.obtain(key, source);
    if (!mounted) {
      baked.dispose();
      return;
    }
    setState(() {
      _baked?.dispose();
      _baked = baked;
      _bakedKey = key;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_blurred) {
      return Image(
        image: widget.image,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        _bakeIfNeeded();
        final baked = _baked;
        // Nothing baked yet (cold start, or a preset switch mid-bake): draw
        // nothing rather than the sharp image, which would pop into focus for
        // a frame. The base colour behind this widget covers the gap, exactly
        // as it does while the image is still decoding today.
        if (baked == null) return const SizedBox.expand();
        return CustomPaint(
          painter: _BakedImagePainter(baked),
          size: Size.infinite,
        );
      },
    );
  }
}

class _BakedImagePainter extends CustomPainter {
  final ui.Image image;

  const _BakedImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // `fill`, not `cover`: the texture was baked by covering this box, so it
    // already *is* the box, and covering a second time would re-crop it by
    // whatever the bake's pixel rounding left of the aspect ratio. Between a
    // resize and the bake that follows it this stretches the previous texture
    // slightly, which is the right transient — it keeps the screen covered.
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _BakedImagePainter old) => old.image != image;
}
