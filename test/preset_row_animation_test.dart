import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/presets/widgets/animated_preset_row.dart';

void main() {
  const rowKey = ValueKey('row-child');

  Widget host({required bool exiting}) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AnimatedPresetRow(
              exiting: exiting,
              child: const SizedBox(key: rowKey, height: 60, width: 100),
            ),
          ],
        ),
      ),
    );
  }

  double rowHeight(WidgetTester tester) =>
      tester.getSize(find.byType(AnimatedPresetRow)).height;

  /// The innermost fade — the one that plays when the row is mounted.
  FadeTransition entryFade(WidgetTester tester) => tester.widget<FadeTransition>(
    find
        .descendant(
          of: find.byType(AnimatedPresetRow),
          matching: find.byType(FadeTransition),
        )
        .last,
  );

  testWidgets('a new row fades in at its full height', (tester) async {
    await tester.pumpWidget(host(exiting: false));

    expect(entryFade(tester).opacity.value, lessThan(1.0));
    // The row must not grow into place: a list full of rows expanding at once
    // would shove everything below them around on open.
    expect(rowHeight(tester), 60);

    await tester.pumpAndSettle();
    expect(entryFade(tester).opacity.value, 1.0);
    expect(rowHeight(tester), 60);
  });

  testWidgets('a deleted row collapses before it is gone', (tester) async {
    await tester.pumpWidget(host(exiting: false));
    await tester.pumpAndSettle();

    await tester.pumpWidget(host(exiting: true));
    await tester.pump();
    expect(rowHeight(tester), 60);

    await tester.pump(AnimatedPresetRow.exitDuration ~/ 2);
    expect(rowHeight(tester), lessThan(60));

    // Fully collapsed by the time the screen commits the delete, so the list
    // closes the gap on an empty slot.
    await tester.pump(AnimatedPresetRow.exitDuration);
    expect(rowHeight(tester), moreOrLessEquals(0, epsilon: 0.01));
  });

  testWidgets('a row that stops exiting is restored at once', (tester) async {
    await tester.pumpWidget(host(exiting: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(exiting: true));
    await tester.pump(AnimatedPresetRow.exitDuration);

    await tester.pumpWidget(host(exiting: false));
    await tester.pump();
    expect(rowHeight(tester), 60);
  });
}
