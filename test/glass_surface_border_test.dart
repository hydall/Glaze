import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/widgets/glass_surface.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  const childColor = Color(0xFFFF0000);
  const borderColor = Color(0xFF0000FF);
  final border = Border.all(color: borderColor, width: 6);
  const boundaryKey = ValueKey('surface-boundary');

  Widget host({required bool borderOnTop}) {
    return ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 100,
                height: 100,
                child: GlassSurface(
                  borderRadius: BorderRadius.circular(12),
                  border: border,
                  borderOnTop: borderOnTop,
                  // A cover image fills the card the same way: edge to edge,
                  // opaque, over every pixel the border would occupy.
                  child: const ColoredBox(color: childColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  BoxBorder? borderAt(WidgetTester tester, DecorationPosition position) {
    for (final box in tester.widgetList<DecoratedBox>(
      find.byType(DecoratedBox),
    )) {
      if (box.position != position) continue;
      final decoration = box.decoration;
      if (decoration is BoxDecoration && decoration.border != null) {
        return decoration.border;
      }
    }
    return null;
  }

  testWidgets('by default the border is painted behind the child', (
    tester,
  ) async {
    await tester.pumpWidget(host(borderOnTop: false));

    expect(borderAt(tester, DecorationPosition.background), border);
    expect(borderAt(tester, DecorationPosition.foreground), isNull);
  });

  testWidgets('borderOnTop moves the border in front of the child', (
    tester,
  ) async {
    await tester.pumpWidget(host(borderOnTop: true));

    expect(borderAt(tester, DecorationPosition.foreground), border);
    expect(borderAt(tester, DecorationPosition.background), isNull);
  });

  testWidgets('borderOnTop keeps the frame visible over a full-bleed child', (
    tester,
  ) async {
    // The reason the flag exists: a card whose child covers the surface edge to
    // edge — a preset cover — otherwise paints its own frame away, taking the
    // active-preset highlight with it.
    Future<Color> edgePixel({required bool borderOnTop}) async {
      await tester.pumpWidget(host(borderOnTop: borderOnTop));
      await tester.pumpAndSettle();

      late Color pixel;
      await tester.runAsync(() async {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(
              find.byKey(boundaryKey),
            );
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        // Two logical pixels in from the left edge, at mid-height: inside the
        // 6px frame, clear of the rounded corners and of the clip's antialiasing.
        final bytes = data!.buffer.asUint8List();
        pixel = _pixelAt(bytes, image.width, x: 2, y: image.height ~/ 2);
        image.dispose();
      });
      return pixel;
    }

    expect(await edgePixel(borderOnTop: true), borderColor);
    // Same surface without the flag: the child owns that pixel.
    expect(await edgePixel(borderOnTop: false), childColor);
  });
}

Color _pixelAt(Uint8List rgba, int width, {required int x, required int y}) {
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    rgba[offset + 3],
    rgba[offset],
    rgba[offset + 1],
    rgba[offset + 2],
  );
}
