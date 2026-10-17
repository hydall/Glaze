import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/plugins/widgets/plugin_holes.dart';
import 'package:glaze_flutter/features/plugins/widgets/plugin_layer.dart';

void main() {
  late PluginHoles holes;
  late List<String> taps;
  final pageKey = GlobalKey();

  setUp(() {
    holes = PluginHoles()..page = () => pageKey.currentContext;
    taps = [];
  });

  tearDown(() => holes.dispose());

  // The page sits 20 px down, the controls over it 100 px down, so the
  // holes go through both offsets.
  Widget app({bool cut = true}) => Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      children: [
        Positioned.fill(
          top: 20,
          child: GestureDetector(
            key: pageKey,
            behavior: HitTestBehavior.opaque,
            onTap: () => taps.add('page'),
          ),
        ),
        Positioned(
          top: 100,
          left: 0,
          right: 0,
          height: 100,
          child: PluginHolesCutter(
            holes: holes,
            enabled: cut,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps.add('controls'),
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ],
    ),
  );

  testWidgets('without holes the controls are whole', (tester) async {
    await tester.pumpWidget(app());
    await tester.tapAt(const Offset(30, 150));
    expect(taps, ['controls']);
  });

  testWidgets('a hole lets taps through to the page', (tester) async {
    await tester.pumpWidget(app());
    // Page y 110..160 is screen y 130..180.
    holes.update([
      [10, 110, 50, 50],
    ]);
    await tester.pump();

    await tester.tapAt(const Offset(30, 150));
    await tester.tapAt(const Offset(100, 150));
    await tester.tapAt(const Offset(30, 190));
    expect(taps, ['page', 'controls', 'controls']);

    holes.clear();
    await tester.pump();
    await tester.tapAt(const Offset(30, 150));
    expect(taps.last, 'controls');
  });

  testWidgets('a hole off the controls changes nothing', (tester) async {
    await tester.pumpWidget(app());
    holes.update([
      [10, 0, 50, 40],
    ]);
    await tester.pump();
    await tester.tapAt(const Offset(30, 110));
    expect(taps, ['controls']);
  });

  test('update keeps only well-formed rects', () {
    var notified = 0;
    holes.addListener(() => notified++);
    holes.update([
      [1, 2, 3, 4],
      [1, 2, 0, 4],
      [1, 2, 3],
      'x',
      [1, double.nan, 3, 4],
    ]);
    expect(holes.rects, [const Rect.fromLTWH(1, 2, 3, 4)]);
    holes.update([
      [1, 2, 3, 4],
    ]);
    expect(notified, 1);
  });

  testWidgets('a cutter that is not enabled leaves the controls whole', (
    tester,
  ) async {
    await tester.pumpWidget(app(cut: false));
    holes.update([
      [10, 110, 50, 50],
    ]);
    await tester.pump();
    await tester.tapAt(const Offset(30, 150));
    expect(taps, ['controls']);
  });

  // The plugin layer over the controls: its page is the layer itself.
  Widget layered() => Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps.add('controls'),
          ),
        ),
        Positioned.fill(
          top: 20,
          child: PluginHolesHitArea(
            holes: holes,
            child: GestureDetector(
              key: pageKey,
              behavior: HitTestBehavior.opaque,
              onTap: () => taps.add('layer'),
            ),
          ),
        ),
      ],
    ),
  );

  testWidgets('the plugin layer takes taps only in the holes', (tester) async {
    await tester.pumpWidget(layered());
    await tester.tapAt(const Offset(30, 150));
    expect(taps, ['controls']);

    // Layer y 110..160 is screen y 130..180.
    holes.update([
      [10, 110, 50, 50],
    ]);
    await tester.pump();
    await tester.tapAt(const Offset(30, 150));
    await tester.tapAt(const Offset(100, 150));
    expect(taps, ['controls', 'layer', 'controls']);
  });

  test('the plugin layer is where touches can be passed down', () {
    expect(pluginLayerSupported(TargetPlatform.android), isTrue);
    expect(pluginLayerSupported(TargetPlatform.windows), isTrue);
    expect(pluginLayerSupported(TargetPlatform.linux), isTrue);
    expect(pluginLayerSupported(TargetPlatform.iOS), isFalse);
    expect(pluginLayerSupported(TargetPlatform.macOS), isFalse);
  });
}
