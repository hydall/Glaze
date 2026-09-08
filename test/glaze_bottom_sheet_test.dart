import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/widgets/glaze_bottom_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget testApp(VoidCallback onOpen) {
    return ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                ElevatedButton(onPressed: onOpen, child: const Text('Open')),
          ),
        ),
      ),
    );
  }

  testWidgets('lazy items only build rows in the viewport', (tester) async {
    var buildCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => GlazeBottomSheet.show<void>(
                  context,
                  itemCount: 100,
                  itemBuilder: (context, index) {
                    buildCount++;
                    return BottomSheetItem(label: 'Item $index', onTap: () {});
                  },
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(buildCount, lessThan(100));
    expect(find.text('Item 99'), findsNothing);
  });

  testWidgets('lazy item tap invokes callback and returns the result', (
    tester,
  ) async {
    var tapped = false;
    String? result;
    late BuildContext sheetContext;

    await tester.pumpWidget(
      testApp(() {
        GlazeBottomSheet.show<String>(
          sheetContext,
          itemCount: 50,
          itemBuilder: (context, index) => BottomSheetItem(
            label: 'Item $index',
            onTap: () {
              tapped = true;
              Navigator.of(context, rootNavigator: true).pop('item-$index');
            },
          ),
        ).then((value) => result = value);
      }),
    );
    sheetContext = tester.element(find.text('Open'));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Item 2'));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
    expect(result, 'item-2');
  });

  testWidgets('materialized items still build every row', (tester) async {
    late BuildContext sheetContext;
    final items = List.generate(
      100,
      (index) => BottomSheetItem(label: 'Item $index', onTap: () {}),
    );

    await tester.pumpWidget(
      testApp(() => GlazeBottomSheet.show<void>(sheetContext, items: items)),
    );
    sheetContext = tester.element(find.text('Open'));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Item 99', skipOffstage: false), findsOneWidget);
  });
}
