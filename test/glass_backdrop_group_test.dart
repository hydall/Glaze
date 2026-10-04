import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:glaze_flutter/shared/widgets/glaze_tab_bar.dart';

/// Backdrop grouping tells the engine that several glass surfaces read the
/// same backdrop, so it blurs once instead of once per surface. Sharing is only
/// correct between surfaces that do not overlap — these pin down who ends up
/// in a group and, more importantly, who does not.
void main() {
  Widget chip(String label) => SizedBox(
    width: 60,
    height: 32,
    child: GlassSurface(
      borderRadius: BorderRadius.circular(16),
      child: Center(child: Text(label)),
    ),
  );

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );

  List<BackdropKey?> keys(WidgetTester tester) => tester
      .widgetList<BackdropFilter>(find.byType(BackdropFilter))
      .map((f) => f.backdropGroupKey)
      .toList();

  testWidgets('siblings in a group share one backdrop key', (tester) async {
    await pump(
      tester,
      GlassBackdropGroup(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [chip('a'), chip('b'), chip('c')],
        ),
      ),
    );

    final shared = keys(tester);
    expect(shared, hasLength(3));
    expect(shared.first, isNotNull);
    expect(shared.every((k) => identical(k, shared.first)), isTrue);
  });

  testWidgets('surfaces outside a group stay independent', (tester) async {
    await pump(
      tester,
      Row(mainAxisSize: MainAxisSize.min, children: [chip('a'), chip('b')]),
    );

    expect(keys(tester), everyElement(isNull));
  });

  testWidgets('a nested surface does not join its parent group', (
    tester,
  ) async {
    await pump(
      tester,
      GlassBackdropGroup(
        child: SizedBox(
          width: 120,
          height: 48,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(16),
            // Stands for the active pill inside a tab strip: it is painted
            // over its parent's own blur, so it can never read the same
            // capture.
            child: chip('pill'),
          ),
        ),
      ),
    );

    final found = keys(tester);
    expect(found, hasLength(2));
    // Outer surface is in the group, the one inside it is not.
    expect(found.first, isNotNull);
    expect(found.last, isNull);
  });

  testWidgets('an explicitly closed subtree leaves the group', (tester) async {
    await pump(
      tester,
      GlassBackdropGroup(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            chip('grouped'),
            GlassBackdropGroup.none(child: chip('excluded')),
          ],
        ),
      ),
    );

    final found = keys(tester);
    expect(found, hasLength(2));
    expect(found.first, isNotNull);
    expect(found.last, isNull);
  });

  testWidgets('a tab strip inside a group keeps its pill ungrouped', (
    tester,
  ) async {
    await pump(
      tester,
      GlassBackdropGroup(
        child: SizedBox(
          width: 320,
          child: GlazeTabBar(
            tabs: const [
              GlazeTabItem(label: 'One', icon: Icons.circle_outlined),
              GlazeTabItem(label: 'Two', icon: Icons.circle_outlined),
            ],
            activeIndex: 0,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final found = keys(tester);
    // The strip joins the group; the active pill sitting on top of it does not
    // — it is painted over the strip's own blur.
    expect(found, hasLength(2));
    expect(found.first, isNotNull);
    expect(found.last, isNull);
  });

  testWidgets('a flat opaque backdrop drops the blur but keeps the fill', (
    tester,
  ) async {
    await pump(
      tester,
      FlatBackdrop(
        color: const Color(0xFF1B1D22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            chip('a'),
            // A subtree can re-open the blur where what is behind it is not
            // flat after all.
            FlatBackdrop(color: null, child: chip('b')),
          ],
        ),
      ),
    );

    // Blurring one uniform colour returns that colour, so the marked surface
    // paints no filter at all; the one that opted back out still does.
    expect(find.byType(BackdropFilter), findsOneWidget);
    // Both still paint their tint and border — only the blur is dropped.
    expect(find.byType(GlassSurface), findsNWidgets(2));
    expect(find.byType(DecoratedBox), findsNWidgets(2));
  });

  testWidgets('compositing against the flat colour paints the same pixels', (
    tester,
  ) async {
    const behind = Color(0xFF1B1D22);

    Future<ByteData> render({required bool told}) async {
      final surface = SizedBox(
        width: 160,
        height: 80,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x33FFFFFF)),
          child: const SizedBox.expand(),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: RepaintBoundary(
              child: ColoredBox(
                color: behind,
                child: Center(
                  child: told
                      ? const FlatBackdrop(color: behind, child: SizedBox())
                      : const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      );
      // Rebuilt with the real child now that the tree shape is settled, so both
      // passes go through the same widget path.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: RepaintBoundary(
              child: ColoredBox(
                color: behind,
                child: Center(
                  child: told
                      ? FlatBackdrop(color: behind, child: surface)
                      : surface,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
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

    final blended = await render(told: true);
    final blurred = await render(told: false);

    expect(blended.lengthInBytes, blurred.lengthInBytes);
    var worst = 0;
    for (var i = 0; i < blurred.lengthInBytes; i++) {
      final delta = (blended.getUint8(i) - blurred.getUint8(i)).abs();
      if (delta > worst) worst = delta;
    }
    // Blurring a flat colour returns that colour, and a tint over it
    // composites to the same thing whether the compositor does it per frame or
    // this does it once. What is left is the rounded rect's antialiased edge,
    // where coverage blending a translucent fill and drawing an opaque one
    // disagree by a couple of steps of an 8-bit channel.
    expect(worst, lessThanOrEqualTo(6), reason: 'worst channel delta');
  });

  testWidgets('the key survives a rebuild', (tester) async {
    Future<BackdropKey?> keyAfterPump(String label) async {
      await pump(
        tester,
        GlassBackdropGroup(key: const ValueKey('group'), child: chip(label)),
      );
      return keys(tester).single;
    }

    final first = await keyAfterPump('a');
    final second = await keyAfterPump('b');
    // A new key per build would mean a new capture every frame — the opposite of
    // what the group is for.
    expect(identical(first, second), isTrue);
  });
}
