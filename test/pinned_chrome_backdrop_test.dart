import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/top_edge_blur.dart';

void main() {
  testWidgets('keeps the pinned chrome scrim when blur is disabled', (
    tester,
  ) async {
    const tint = Color(0xE0112233);

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 320,
          height: 240,
          child: TopEdgeBlur(
            enabled: false,
            height: 80,
            tintColor: tint,
            child: ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );

    final decorated = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(TopEdgeBlur),
        matching: find.byType(DecoratedBox),
      ),
    );
    final gradient = (decorated.decoration as BoxDecoration).gradient!;

    expect(gradient.colors.first, tint);
    expect(gradient.colors.last.a, 0);
    expect(tester.getSize(find.byType(DecoratedBox)).height, 80);
  });

  test('all pinned chrome containers use a strong shared scrim', () {
    final sources = [
      File('lib/shared/widgets/sheet_view.dart').readAsStringSync(),
      File('lib/shared/widgets/glaze_bottom_sheet.dart').readAsStringSync(),
      File(
        'lib/features/chat/widgets/drawer_panel_scaffold.dart',
      ).readAsStringSync(),
    ];

    for (final source in sources) {
      final backdropStart = source.indexOf('TopEdgeBlur(');
      final backdropEnd = source.indexOf('child:', backdropStart);
      final backdrop = source.substring(backdropStart, backdropEnd);

      expect(backdropStart, isNonNegative);
      expect(backdrop, contains('alpha: 0.88'));
      expect(backdrop, isNot(contains('alpha: 0.4')));
    }
  });

  test('route SheetView applies the backdrop before its fixed header', () {
    final source = File(
      'lib/shared/widgets/sheet_view.dart',
    ).readAsStringSync();
    final routeStart = source.indexOf('if (!_inModalSheet)');
    final routeEnd = source.indexOf('return PopScope(', routeStart);
    final routeBranch = source.substring(routeStart, routeEnd);

    expect(routeBranch, contains('return TopEdgeBlur('));
    expect(routeBranch, contains('extraTop + 8'));
    // The scrim is only painted over a header the sheet actually pins; a
    // chrome-drawing host leaves it with none, so no stale band.
    expect(routeBranch, contains('_hasHeader'));
  });

  testWidgets('samples only the top strip, not the full child subtree', (
    tester,
  ) async {
    TopEdgeBlur.debugLastSampleHeight = null;

    await tester.pumpWidget(
      const MaterialApp(
        home: TopEdgeBlur(
          height: 60,
          sigma: 24,
          child: ColoredBox(color: Colors.white),
        ),
      ),
    );
    await tester.pump();

    final sampled = TopEdgeBlur.debugLastSampleHeight;
    expect(sampled, isNotNull);
    // strip (60) + blur margin (2 * sigma + 4), never the whole child.
    expect(sampled!, lessThanOrEqualTo(60 + 24 * 2 + 4 + 0.001));
  });

  testWidgets('capturing the strip below device resolution does not show', (
    tester,
  ) async {
    addTearDown(() => TopEdgeBlur.debugSampleRatioOverride = null);
    tester.view.physicalSize = const Size(1080, 600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // Hard horizontal edges right under the strip: the blur has to smear them,
    // and a capture too coarse to carry the result shows its own grid doing it.
    Widget strip() => Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        child: TopEdgeBlur(
          height: 90,
          sigma: 24,
          tintColor: const Color(0x66223344),
          child: Column(
            children: [
              for (var i = 0; i < 12; i++)
                Expanded(
                  child: ColoredBox(
                    color: i.isEven
                        ? const Color(0xFFF0A020)
                        : const Color(0xFF203040),
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    Future<ByteData> render(double? ratio) async {
      TopEdgeBlur.debugSampleRatioOverride = ratio;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(strip());
      await tester.pump();
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

    // What the strip cost before: one capture at the device's full resolution.
    final reference = await render(3);
    final reduced = await render(null);

    expect(
      TopEdgeBlur.sampleRatioFor(24, 3),
      lessThan(3),
      reason: 'the capture should be coarser than the device',
    );

    expect(reduced.lengthInBytes, reference.lengthInBytes);
    var worst = 0;
    var total = 0;
    for (var i = 0; i < reference.lengthInBytes; i++) {
      final delta = (reduced.getUint8(i) - reference.getUint8(i)).abs();
      total += delta;
      if (delta > worst) worst = delta;
    }
    final mean = total / reference.lengthInBytes;
    // A sigma-24 blur carries nothing finer than its own kernel, so capturing
    // the strip at a sixth of the device's resolution — a thirty-sixth of the
    // pixels, every frame the strip is resampled — measures 0.33/255 mean and
    // 6/255 worst against capturing it at full resolution.
    expect(mean, lessThan(1.5), reason: 'mean channel delta');
    expect(worst, lessThanOrEqualTo(16), reason: 'worst channel delta');
  });
}
