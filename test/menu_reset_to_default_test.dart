import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/widgets/menu_group.dart';

import 'helpers/pump_localized.dart';

/// The reset affordance on the API tab's parameter rows. The caller passes
/// `onReset` only while a value differs from its default, so the widgets only
/// have to draw it and call it back.
void main() {
  testWidgets('MenuFieldItem hides the reset button without onReset', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      MenuFieldItem(label: 'Max tokens', controller: TextEditingController()),
    );

    expect(find.byIcon(Icons.undo_rounded), findsNothing);
  });

  testWidgets('MenuFieldItem draws the reset button and calls it back', (
    tester,
  ) async {
    var resets = 0;
    await pumpLocalized(
      tester,
      MenuFieldItem(
        label: 'Max tokens',
        controller: TextEditingController(text: '4096'),
        onReset: () => resets++,
      ),
    );

    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.undo_rounded));
    expect(resets, 1);
  });

  testWidgets('MenuRangeItem draws the reset button and calls it back', (
    tester,
  ) async {
    var resets = 0;
    await pumpLocalized(
      tester,
      MenuRangeItem(
        label: 'Temperature',
        value: 1.5,
        min: 0,
        max: 2,
        editableValue: true,
        onChanged: (_) {},
        onReset: () => resets++,
      ),
    );

    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.undo_rounded));
    expect(resets, 1);
  });

  testWidgets('MenuSelectorItem draws the reset button and calls it back', (
    tester,
  ) async {
    var resets = 0;
    await pumpLocalized(
      tester,
      MenuSelectorItem(
        label: 'Reasoning effort',
        currentValue: 'high',
        onTap: () {},
        onReset: () => resets++,
      ),
    );

    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.undo_rounded));
    expect(resets, 1);
  });
}
