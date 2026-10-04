import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/baked_blur.dart';
import 'package:glaze_flutter/shared/widgets/card_backdrop.dart';

/// A card that samples a baked backdrop has to be indistinguishable from one
/// that runs a real `BackdropFilter` — that is the whole contract. These render
/// both and compare pixels, including under a transform, which is where the
/// obvious implementation (an axis-aligned crop at the card's global rect)
/// comes apart.
const double _bgSigma = 20;
const double _cardSigma = 12;
const double _dim = 0.15;
const Rect _card = Rect.fromLTWH(40, 220, 280, 180);

Future<Uint8List> _sourcePng() async {
  const width = 400.0;
  const height = 700.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF102030),
  );
  for (var y = 0; y < height; y += 40) {
    canvas.drawRect(
      Rect.fromLTWH(0, y.toDouble(), width, 20),
      Paint()
        ..color = (y ~/ 40).isEven
            ? const Color(0xFFF0A020)
            : const Color(0xFF20C0F0),
    );
  }
  canvas.drawCircle(
    const Offset(200, 350),
    90,
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), height.toInt());
  picture.dispose();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

/// The app background as [GlazeBackground] paints it: the image blurred by the
/// preset's `bgBlur`, then a flat dim over it.
///
/// Drawn from an already-decoded image rather than `Image.memory`, so a capture
/// can never race the codec.
Widget _background(ui.Image source) => Stack(
  fit: StackFit.expand,
  children: [
    ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: _bgSigma,
        sigmaY: _bgSigma,
        tileMode: TileMode.clamp,
      ),
      child: RawImage(image: source, fit: BoxFit.cover),
    ),
    ColoredBox(color: Colors.black.withValues(alpha: _dim)),
  ],
);

Widget _screen(ui.Image source, Widget card, {Matrix4? transform}) {
  final positioned = Positioned.fromRect(
    rect: _card,
    child: ClipRRect(borderRadius: BorderRadius.circular(20), child: card),
  );
  return Directionality(
    textDirection: TextDirection.ltr,
    child: RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _background(source),
          if (transform == null)
            positioned
          else
            Positioned.fill(
              child: Transform(
                transform: transform,
                child: Stack(fit: StackFit.expand, children: [positioned]),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The same card inside a scrolling list, which is where the texture has to
/// stay put on its own: a list moves its children by mutating layer offsets,
/// without repainting them.
Widget _scrolled(ui.Image source, Widget card, ScrollController controller) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _background(source),
            ListView(
              controller: controller,
              children: [
                const SizedBox(height: 320),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: SizedBox(
                    height: 180,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: card,
                    ),
                  ),
                ),
                const SizedBox(height: 1400),
              ],
            ),
          ],
        ),
      ),
    );

/// Same fill a glass surface paints over its blur.
Widget get _fill =>
    ColoredBox(color: const Color(0xFF889099).withValues(alpha: 0.4));

Future<ByteData> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  late ByteData bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    bytes = (await image.toByteData())!;
    image.dispose();
  });
  return bytes;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

({double mean, int worst}) _compare(ByteData a, ByteData b) {
  var worst = 0;
  var total = 0;
  for (var i = 0; i < a.lengthInBytes; i++) {
    final delta = (a.getUint8(i) - b.getUint8(i)).abs();
    total += delta;
    if (delta > worst) worst = delta;
  }
  return (mean: total / a.lengthInBytes, worst: worst);
}

void main() {
  late Uint8List png;
  late ui.Image source;
  late CardBackdropData data;

  setUp(BakedBlurCache.clear);
  tearDown(BakedBlurCache.clear);

  Future<void> prepare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    png = (await tester.runAsync(_sourcePng))!;
    source = (await tester.runAsync(() => _decode(png)))!;
    addTearDown(source.dispose);
    const size = Size(360, 780);
    final key = BakedBlurKey(
      provider: MemoryImage(png),
      sigma: CardBackdrop.combineSigma(_bgSigma, _cardSigma),
      dim: _dim,
      size: size,
      devicePixelRatio: 3,
    );
    data = CardBackdropData(BakedBlurCache.obtain(key, source), key.scale);
  }

  testWidgets('a sampled card matches a real BackdropFilter', (tester) async {
    await prepare(tester);

    await tester.pumpWidget(
      _screen(
        source,
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: _cardSigma, sigmaY: _cardSigma),
          child: _fill,
        ),
      ),
    );
    await _settle(tester);
    final reference = await _capture(tester);

    await tester.pumpWidget(
      _screen(source, CardBackdropSample(data: data, child: _fill)),
    );
    await _settle(tester);
    final sampled = await _capture(tester);

    final diff = _compare(sampled, reference);
    // Not bit-identical: the bake rounds to 8-bit pixels once more and is
    // rasterised at a fraction of the device resolution, which a blur this wide
    // cannot carry detail past anyway. Measured on this deliberately hard-edged
    // source it comes out at 0.08/255 mean and 3/255 worst.
    expect(diff.mean, lessThan(1), reason: 'mean channel delta');
    expect(diff.worst, lessThanOrEqualTo(10), reason: 'worst channel delta');
  });

  testWidgets('the sample stays pinned to the screen under a transform', (
    tester,
  ) async {
    await prepare(tester);
    // Roughly the Android overscroll stretch: content scaled about the top
    // edge. A real backdrop filter keeps showing the unstretched background
    // through the stretched card; an axis-aligned crop at the card's global
    // rect would drag the background along with it.
    final stretch = Matrix4.identity()..scaleByDouble(1.0, 1.3, 1.0, 1.0);

    await tester.pumpWidget(
      _screen(
        source,
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: _cardSigma, sigmaY: _cardSigma),
          child: _fill,
        ),
        transform: stretch,
      ),
    );
    await _settle(tester);
    final reference = await _capture(tester);

    await tester.pumpWidget(
      _screen(
        source,
        CardBackdropSample(data: data, child: _fill),
        transform: stretch,
      ),
    );
    await _settle(tester);
    final sampled = await _capture(tester);

    final diff = _compare(sampled, reference);
    // 0.11/255 mean, 3/255 worst as written. Sampling an axis-aligned crop at
    // the card's global rect instead — the obvious implementation — measures
    // 2.1 and 71 here, so this is what holds the shader in place.
    expect(diff.mean, lessThan(1), reason: 'mean channel delta');
    expect(diff.worst, lessThanOrEqualTo(10), reason: 'worst channel delta');
  });

  testWidgets('the sample follows the screen while the list scrolls', (
    tester,
  ) async {
    await prepare(tester);
    const scrollTo = 140.0;

    Future<ByteData> render(Widget card) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_scrolled(source, card, controller));
      await _settle(tester);
      controller.jumpTo(scrollTo);
      await _settle(tester);
      return _capture(tester);
    }

    final reference = await render(
      BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: _cardSigma, sigmaY: _cardSigma),
        child: _fill,
      ),
    );
    final sampled = await render(CardBackdropSample(data: data, child: _fill));

    final diff = _compare(sampled, reference);
    // The card ends up 140px further up the screen than it started, over a
    // different part of the background.
    expect(diff.mean, lessThan(1), reason: 'mean channel delta');
    expect(diff.worst, lessThanOrEqualTo(10), reason: 'worst channel delta');

    // The result above is necessary but not sufficient: this harness repaints
    // the list's children on a jumpTo, where a real scroll only moves their
    // layers. So assert the mechanism separately — the placement has to be
    // recomputed while the scene is built, not while the box is painted.
    final sample = tester.renderObject<RenderCardBackdropSample>(
      find.byType(CardBackdropSample),
    );
    expect(sample.debugPlacesPerScene, isTrue);
  });

  testWidgets('a closed scope hands out no backdrop', (tester) async {
    await prepare(tester);
    CardBackdropData? inside;
    CardBackdropData? outside;

    Widget probe(void Function(CardBackdropData?) sink) => Builder(
      builder: (context) {
        sink(CardBackdrop.of(context));
        return const SizedBox.shrink();
      },
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CardBackdrop(
          image: MemoryImage(png),
          sigma: CardBackdrop.combineSigma(_bgSigma, _cardSigma),
          dim: _dim,
          child: Column(
            children: [
              probe((d) => outside = d),
              CardBackdrop.closed(child: probe((d) => inside = d)),
            ],
          ),
        ),
      ),
    );
    await _settle(tester);

    // The texture the outer scope hands out is the same bake `prepare` already
    // put in the cache, so this also pins that the cache is shared rather than
    // per widget.
    expect(outside, isNotNull);
    expect(outside!.image.width, data.image.width);
    expect(inside, isNull, reason: 'a closed scope must sample nothing');
  });
}
