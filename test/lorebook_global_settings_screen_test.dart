import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart';
import 'package:glaze_flutter/features/lorebooks/lorebook_global_settings_screen.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'global lorebook vector slider rebuilds without framework error',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          lorebookSettingsProvider.overrideWith(
            (_) => const LorebookGlobalSettings(searchType: 'vector'),
          ),
          // The vector section only renders while the active API preset has
          // semantic search on; this test is about the slider, not the gate.
          vectorSearchAvailableProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LorebookGlobalSettingsScreen()),
        ),
      );

      expect(find.byType(Slider), findsOneWidget);

      await tester.ensureVisible(find.byType(Slider));
      await tester.pump();
      await tester.drag(find.byType(Slider), const Offset(120, 0));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(container.read(lorebookSettingsProvider).searchType, 'vector');
    },
  );

  testWidgets('the vector section is gone while semantic search is off', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        lorebookSettingsProvider.overrideWith(
          (_) => const LorebookGlobalSettings(searchType: 'vector'),
        ),
        vectorSearchAvailableProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LorebookGlobalSettingsScreen()),
      ),
    );

    // The similarity-threshold slider lives in the vector section, which the
    // gate drops entirely — the stored 'vector' search type is left untouched.
    expect(find.byType(Slider), findsNothing);
    expect(container.read(lorebookSettingsProvider).searchType, 'vector');
  });
}
