import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

/// An expanded modal sheet covers the screen, but its route is not opaque, so
/// Flutter keeps painting the screen underneath — blurs and all — for nothing.
/// [SheetView] marks the route's barrier entry opaque while that is genuinely
/// the case. These pin *when* it does, because the cost of getting it wrong is
/// the screen below showing through a gap that is no longer covered.
void main() {
  bool occluding(WidgetTester tester) {
    final route = ModalRoute.of(tester.element(find.byType(SheetView)))!;
    return route.overlayEntries.first.opaque;
  }

  Future<void> open(
    WidgetTester tester, {
    required bool expanded,
    Size screen = const Size(400, 800),
  }) async {
    tester.view.physicalSize = screen * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => SheetView(
                    startExpanded: expanded,
                    title: 'Sheet',
                    body: ListView(
                      children: [
                        for (var i = 0; i < 20; i++)
                          SizedBox(height: 60, child: Text('row $i')),
                      ],
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
  }

  testWidgets('the screen below keeps painting all through the slide-in', (
    tester,
  ) async {
    await open(tester, expanded: true);

    // Halfway up: the sheet does not cover the screen yet, and the barrier is
    // what the screen below is seen through.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      occluding(tester),
      isFalse,
      reason:
          'occluding mid-transition would blank the screen behind the sheet',
    );

    await tester.pumpAndSettle();
    expect(occluding(tester), isTrue);
  });

  testWidgets('a sheet that does not reach the top never occludes', (
    tester,
  ) async {
    await open(tester, expanded: false);
    await tester.pumpAndSettle();

    // Collapsed: the barrier is visible above the sheet, so the screen behind
    // it has to keep painting.
    expect(occluding(tester), isFalse);
  });

  testWidgets('flicking an expanded sheet away hands the screen back', (
    tester,
  ) async {
    await open(tester, expanded: true);
    await tester.pumpAndSettle();
    expect(occluding(tester), isTrue);
    final barrier = ModalRoute.of(
      tester.element(find.byType(SheetView)),
    )!.overlayEntries.first;

    // From the drag handle at the top of the sheet — a drag on the body
    // scrolls instead. Far enough to dismiss, which is the case that would
    // otherwise leave the screen below off stage with nothing over it.
    await tester.dragFrom(const Offset(200, 14), const Offset(0, 420));
    await tester.pumpAndSettle();

    expect(find.byType(SheetView), findsNothing);
    expect(barrier.opaque, isFalse);
  });

  testWidgets('a sheet narrower than the screen never occludes', (
    tester,
  ) async {
    // A bottom sheet is capped at 640 logical pixels wide, so on a wide window
    // the barrier shows down both sides however tall the sheet is.
    await open(tester, expanded: true, screen: const Size(1000, 700));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(SheetView)).width, lessThan(1000));
    expect(occluding(tester), isFalse);
  });

  testWidgets('closing the sheet leaves nothing occluded', (tester) async {
    await open(tester, expanded: true);
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.byType(SheetView)))!;
    final barrier = route.overlayEntries.first;
    expect(barrier.opaque, isTrue);

    Navigator.of(tester.element(find.byType(SheetView))).pop();
    await tester.pumpAndSettle();

    expect(barrier.opaque, isFalse);
  });
}
