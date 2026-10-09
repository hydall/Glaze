import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart';
import 'package:glaze_flutter/features/lorebooks/widgets/lorebook_global_settings_section.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

/// Without EasyLocalization `.tr()` returns the key, so the rows are found by
/// their translation keys.
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  Future<ProviderContainer> pumpSection(
    WidgetTester tester, {
    ApiConfig? embedding,
    LorebookGlobalSettings settings = const LorebookGlobalSettings(),
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        activeEmbeddingConfigProvider.overrideWithValue(embedding),
        lorebookSettingsProvider.overrideWith((_) => settings),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: LorebookGlobalSettingsSection()),
          ),
        ),
      ),
    );
    await tester.tap(find.text('section_global_settings'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> pickSearchType(WidgetTester tester, String label) async {
    await tester.tap(find.text('label_search_type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'picking a vector mode without embeddings falls back to keys and '
    'offers the setup',
    (tester) async {
      final container = await pumpSection(
        tester,
        settings: const LorebookGlobalSettings(searchType: 'vector'),
      );

      await pickSearchType(tester, 'search_type_vector');

      expect(container.read(lorebookSettingsProvider).searchType, 'keyword');
      expect(find.text('vectors_setup_title'), findsOneWidget);
      expect(find.text('vectors_setup_open'), findsOneWidget);
      expect(find.text('label_auto_index_vectors'), findsNothing);
    },
  );

  testWidgets('a configured embedding connection keeps the vector mode', (
    tester,
  ) async {
    final container = await pumpSection(
      tester,
      embedding: const ApiConfig(
        id: 'embedding',
        embeddingEnabled: true,
        embeddingUseSame: false,
        embeddingEndpoint: 'https://vectors.example/v1',
        embeddingModel: 'text-embedding-3-small',
      ),
    );
    expect(find.text('label_auto_index_vectors'), findsNothing);

    await pickSearchType(tester, 'search_type_both');

    expect(container.read(lorebookSettingsProvider).searchType, 'both');
    expect(find.text('vectors_setup_title'), findsNothing);
    expect(find.text('label_auto_index_vectors'), findsOneWidget);
  });
}
