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

  /// Three rows with distinct labels, opened as a searchable sheet.
  Future<void> pumpSearchSheet(
    WidgetTester tester, {
    required bool batterySaver,
  }) async {
    // Pinned as a mode, not just the resolved bool: under the `system` default
    // the notifier asks the platform and overwrites whatever was seeded here.
    SharedPreferences.setMockInitialValues({
      'batterySaver': batterySaver,
      'batterySaverMode': batterySaver ? 'on' : 'off',
    });
    late BuildContext sheetContext;
    final items = [
      BottomSheetItem(label: 'gpt-4o-mini', onTap: () {}),
      BottomSheetItem(label: 'claude-opus', onTap: () {}),
      BottomSheetItem(label: 'gemini-pro', onTap: () {}),
    ];

    await tester.pumpWidget(
      testApp(
        () => GlazeBottomSheet.show<void>(
          sheetContext,
          items: items,
          searchable: true,
          searchHint: 'Search models',
        ),
      ),
    );
    sheetContext = tester.element(find.text('Open'));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('search field filters the rows down to the matches', (
    tester,
  ) async {
    await pumpSearchSheet(tester, batterySaver: false);

    expect(find.text('Search models'), findsOneWidget);
    expect(find.text('claude-opus'), findsOneWidget);

    // Tokens match independently, so "gpt 4o" still finds "gpt-4o-mini".
    await tester.enterText(find.byType(TextField), 'gpt 4o');
    await tester.pumpAndSettle();

    expect(find.text('gpt-4o-mini'), findsOneWidget);
    expect(find.text('claude-opus'), findsNothing);
    expect(find.text('gemini-pro'), findsNothing);
  });

  testWidgets('filtered-out rows animate away instead of popping', (
    tester,
  ) async {
    await pumpSearchSheet(tester, batterySaver: false);

    await tester.enterText(find.byType(TextField), 'gpt');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // Mid-flight: the row is collapsing, so it is still mounted.
    expect(find.text('claude-opus'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('claude-opus'), findsNothing);
  });

  testWidgets('battery saver drops the filter animation', (tester) async {
    await pumpSearchSheet(tester, batterySaver: true);

    await tester.enterText(find.byType(TextField), 'gpt');
    await tester.pump();

    // No transition to wait out — the row is gone on the very next frame.
    expect(find.text('claude-opus'), findsNothing);
    expect(find.text('gpt-4o-mini'), findsOneWidget);
  });

  testWidgets('search shows an empty state when nothing matches', (
    tester,
  ) async {
    await pumpSearchSheet(tester, batterySaver: false);

    await tester.enterText(find.byType(TextField), 'nothing-matches-this');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
    expect(find.text('gpt-4o-mini'), findsNothing);

    // Clearing restores every row.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.search_off_rounded), findsNothing);
    expect(find.text('gpt-4o-mini'), findsOneWidget);
    expect(find.text('claude-opus'), findsOneWidget);
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
