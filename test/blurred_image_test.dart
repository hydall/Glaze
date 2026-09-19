import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/baked_blur.dart';
import 'package:glaze_flutter/shared/widgets/blurred_image.dart';

/// A small, deliberately high-contrast source: hard edges are what a Gaussian
/// blur changes most, so a parity check on this image is a strict one.
Future<Uint8List> _sourcePng() async {
  const width = 40.0;
  const height = 60.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF102030),
  );
  for (var y = 0; y < height; y += 6) {
    canvas.drawRect(
      Rect.fromLTWH(0, y.toDouble(), width, 3),
      Paint()
        ..color = (y ~/ 6).isEven
            ? const Color(0xFFF0A020)
            : const Color(0xFF20C0F0),
    );
  }
  canvas.drawCircle(
    const Offset(width / 2, height / 2),
    12,
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), height.toInt());
  picture.dispose();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

Widget _boxed(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: RepaintBoundary(
      child: SizedBox(width: 90, height: 140, child: child),
    ),
  ),
);

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

/// Pumps until the provider has decoded and the post-frame bake has landed.
/// Image decoding is real async, so it only progresses inside [runAsync].
Future<void> _settle(WidgetTester tester, {int? expectedBakeCount}) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    if (expectedBakeCount != null &&
        BakedBlurCache.bakeCount >= expectedBakeCount) {
      return;
    }
    if (expectedBakeCount == null && i == 7) return;
  }
  fail('Timed out waiting for the baked blur');
}

void main() {
  late Uint8List png;

  setUp(BakedBlurCache.clear);
  tearDown(BakedBlurCache.clear);

  testWidgets('paints what ImageFiltered would have painted', (tester) async {
    png = (await tester.runAsync(_sourcePng))!;
    const sigma = 6.0;

    await tester.pumpWidget(
      _boxed(
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
          child: Image.memory(png, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      ),
    );
    await _settle(tester);
    final reference = await _capture(tester);

    await tester.pumpWidget(
      _boxed(BlurredImage(image: MemoryImage(png), sigma: sigma)),
    );
    await _settle(tester, expectedBakeCount: 1);
    final baked = await _capture(tester);

    expect(baked.lengthInBytes, reference.lengthInBytes);
    var worst = 0;
    var differing = 0;
    var total = 0;
    for (var i = 0; i < reference.lengthInBytes; i++) {
      final delta = (baked.getUint8(i) - reference.getUint8(i)).abs();
      total += delta;
      if (delta > 0) differing++;
      if (delta > worst) worst = delta;
    }
    final mean = total / reference.lengthInBytes;
    // Not bit-identical, and it cannot be: the baked path rounds to 8-bit
    // premultiplied pixels once more than the widget layer does, on its way
    // through the offscreen. What it has to be is invisible — on this
    // deliberately hard-edged source the mean error is ~1/255 and the worst
    // single channel ~5/255, on an image that is then dimmed and covered.
    expect(mean, lessThan(2), reason: 'mean channel delta');
    expect(worst, lessThanOrEqualTo(8), reason: 'worst channel delta');
    expect(differing, greaterThan(0), reason: 'sanity: both sides rendered');
  });

  testWidgets('blurs once and reuses the bake across repaints', (tester) async {
    png = (await tester.runAsync(_sourcePng))!;
    BakedBlurCache.debugResetBakeCount();

    await tester.pumpWidget(
      _boxed(BlurredImage(image: MemoryImage(png), sigma: 6)),
    );
    await _settle(tester, expectedBakeCount: 1);
    expect(BakedBlurCache.bakeCount, 1);

    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(
        _boxed(BlurredImage(image: MemoryImage(png), sigma: 6)),
      );
      await _settle(tester);
    }
    expect(BakedBlurCache.bakeCount, 1);
    expect(BakedBlurCache.size, 1);
  });

  testWidgets('re-bakes when the sigma changes, and caches both', (
    tester,
  ) async {
    png = (await tester.runAsync(_sourcePng))!;
    BakedBlurCache.debugResetBakeCount();

    await tester.pumpWidget(
      _boxed(BlurredImage(image: MemoryImage(png), sigma: 6)),
    );
    await _settle(tester, expectedBakeCount: 1);
    await tester.pumpWidget(
      _boxed(BlurredImage(image: MemoryImage(png), sigma: 9)),
    );
    await _settle(tester, expectedBakeCount: 2);

    expect(BakedBlurCache.bakeCount, 2);
    expect(BakedBlurCache.size, 2);
  });

  testWidgets('never bakes at sigma zero', (tester) async {
    png = (await tester.runAsync(_sourcePng))!;
    BakedBlurCache.debugResetBakeCount();

    await tester.pumpWidget(
      _boxed(BlurredImage(image: MemoryImage(png), sigma: 0)),
    );
    await _settle(tester);

    expect(BakedBlurCache.bakeCount, 0);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
  });

  testWidgets('bakes after the blur is switched on, without an image change', (
    tester,
  ) async {
    png = (await tester.runAsync(_sourcePng))!;
    BakedBlurCache.debugResetBakeCount();

    // Boot with no blur — the Battery Saver ON case — so no source is ever
    // resolved.
    await tester.pumpWidget(
      _boxed(BlurredImage(image: MemoryImage(png), sigma: 0)),
    );
    await _settle(tester);
    expect(BakedBlurCache.bakeCount, 0);

    // Battery Saver OFF: same image, blur switched on.
    await tester.pumpWidget(
      _boxed(BlurredImage(image: MemoryImage(png), sigma: 6)),
    );
    await _settle(tester, expectedBakeCount: 1);

    expect(BakedBlurCache.bakeCount, 1);
  });
}
