import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

/// A sheet whose body has inner state of its own — a folder, a selection, an
/// inline editor — keeps the back gesture for itself until that state is gone.
/// The Presets list relies on this to step out of a folder before it closes.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('back goes to onBack while canPop is false, then closes', (
    tester,
  ) async {
    final canPop = ValueNotifier<bool>(false);
    addTearDown(canPop.dispose);
    var backs = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => ValueListenableBuilder<bool>(
                    valueListenable: canPop,
                    builder: (_, value, _) => SheetView(
                      title: 'Presets',
                      showBack: true,
                      canPop: value,
                      onBack: () => backs++,
                      body: const Text('sheet body'),
                    ),
                  ),
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
    expect(find.text('sheet body'), findsOneWidget);

    // Blocked: the body unwinds one level instead of the sheet vanishing.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(backs, 1);
    expect(find.text('sheet body'), findsOneWidget);

    // Nothing left inside — now back closes the sheet itself.
    canPop.value = true;
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(backs, 1);
    expect(find.text('sheet body'), findsNothing);
  });
}
