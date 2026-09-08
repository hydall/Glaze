import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/widgets/glaze_toast.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildTestApp({required Widget child}) {
    return ProviderScope(
      child: MaterialApp(
        home: Overlay(
          key: toastOverlayKey,
          initialEntries: [
            OverlayEntry(builder: (_) => Scaffold(body: child)),
          ],
        ),
      ),
    );
  }

  tearDown(() {
    GlazeToast.hide();
  });

  testWidgets('GlazeToast.show renders toast text above content',
      (tester) async {
    await tester.pumpWidget(buildTestApp(
      child: Builder(
        builder: (context) {
          return ElevatedButton(
            onPressed: () => GlazeToast.show(context, 'Hello toast'),
            child: const Text('Show Toast'),
          );
        },
      ),
    ));

    await tester.tap(find.text('Show Toast'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(find.text('Hello toast'), findsOneWidget,
        reason: 'Toast text should be visible in the overlay');

    GlazeToast.hide();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });

  testWidgets('GlazeToast.error renders error toast at top',
      (tester) async {
    await tester.pumpWidget(buildTestApp(
      child: Builder(
        builder: (context) {
          return ElevatedButton(
            onPressed: () => GlazeToast.error(context, 'Err: ', 'bad thing'),
            child: const Text('Show Error'),
          );
        },
      ),
    ));

    await tester.tap(find.text('Show Error'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(find.textContaining('Err: bad thing'), findsOneWidget,
        reason: 'Error toast text should be visible');

    GlazeToast.hide();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });

  testWidgets('GlazeToast.showWithoutContext works without BuildContext',
      (tester) async {
    await tester.pumpWidget(buildTestApp(
      child: ElevatedButton(
        onPressed: () => GlazeToast.showWithoutContext('Contextless toast'),
        child: const Text('Show'),
      ),
    ));

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(find.text('Contextless toast'), findsOneWidget,
        reason: 'Toast should appear using the top-level overlay key');

    GlazeToast.hide();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });

  testWidgets('Toast appears above modal bottom sheet', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Overlay(
          key: toastOverlayKey,
          initialEntries: [
            OverlayEntry(
              builder: (_) => Scaffold(
                body: Builder(
                  builder: (context) {
                    return ElevatedButton(
                      onPressed: () {
                        showModalBottomSheet<void>(
                          context: context,
                          useRootNavigator: true,
                          builder: (sheetCtx) {
                            return Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Sheet Content'),
                                  ElevatedButton(
                                    onPressed: () =>
                                        GlazeToast.show(sheetCtx, 'From sheet'),
                                    child: const Text('Toast from sheet'),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                      child: const Text('Open Sheet'),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ));

    await tester.tap(find.text('Open Sheet'));
    await tester.pumpAndSettle();

    expect(find.text('Sheet Content'), findsOneWidget,
        reason: 'Bottom sheet should be visible');

    await tester.tap(find.text('Toast from sheet'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(find.text('From sheet'), findsOneWidget,
        reason: 'Toast should render above the modal bottom sheet');

    GlazeToast.hide();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });

  testWidgets('New toast replaces previous toast', (tester) async {
    await tester.pumpWidget(buildTestApp(
      child: Builder(
        builder: (context) {
          return Column(
            children: [
              ElevatedButton(
                onPressed: () => GlazeToast.show(context, 'First'),
                child: const Text('T1'),
              ),
              ElevatedButton(
                onPressed: () => GlazeToast.show(context, 'Second'),
                child: const Text('T2'),
              ),
            ],
          );
        },
      ),
    ));

    await tester.tap(find.text('T1'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('First'), findsOneWidget);

    await tester.tap(find.text('T2'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('Second'), findsOneWidget,
        reason: 'Second toast should replace the first');

    GlazeToast.hide();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });
}
