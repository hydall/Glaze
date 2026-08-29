import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/preset_folder.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/preset_folder_provider.dart';
import 'package:glaze_flutter/features/presets/preset_list_screen.dart';

import 'helpers/pump_glaze_app.dart';
import 'helpers/test_container.dart';

/// The Presets list opens on the folder the active preset is filed into: a
/// preset inside a folder is not listed at the top level, so opening there
/// would show no highlighted row and leave the user hunting for it.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUpAll(initLocalizationOnce);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = makeContainer(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> seedPreset(String id, String name) async {
    await container.read(presetRepoProvider).put(Preset(id: id, name: name));
  }

  Future<PresetFolder> seedFolder(String name, List<String> presetIds) async {
    final repo = container.read(presetFolderRepoProvider);
    final folder = await repo.create(name: name);
    for (final id in presetIds) {
      await repo.addMember(folder.id, id, PresetKind.normal);
    }
    return folder;
  }

  Future<void> pumpList(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: EasyLocalization(
            supportedLocales: const [Locale('en')],
            path: 'assets/translations',
            fallbackLocale: const Locale('en'),
            child: const MaterialApp(
              home: PresetListScreen(startExpanded: true),
            ),
          ),
        ),
      );
      // The folder memberships arrive over a stream, so the screen first builds
      // without them — exactly as it does on a real open.
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
  }

  testWidgets('opens the folder holding the active preset', (tester) async {
    await seedPreset('p_in_folder', 'Filed preset');
    await seedPreset('p_loose', 'Loose preset');
    await seedFolder('Roleplay', ['p_in_folder']);
    container.read(activePresetIdProvider.notifier).state = 'p_in_folder';

    await pumpList(tester);

    // The folder's own list: its preset is on screen, the top level's is not,
    // and the header names the folder.
    expect(find.text('Filed preset'), findsOneWidget);
    expect(find.text('Loose preset'), findsNothing);
    expect(find.text('Roleplay'), findsOneWidget);
  });

  testWidgets('stays at the top level when the active preset is loose', (
    tester,
  ) async {
    await seedPreset('p_in_folder', 'Filed preset');
    await seedPreset('p_loose', 'Loose preset');
    await seedFolder('Roleplay', ['p_in_folder']);
    container.read(activePresetIdProvider.notifier).state = 'p_loose';

    await pumpList(tester);

    expect(find.text('Loose preset'), findsOneWidget);
    expect(find.text('Filed preset'), findsNothing);
  });

  testWidgets('activating another preset does not move the list again', (
    tester,
  ) async {
    await seedPreset('p_in_folder', 'Filed preset');
    await seedPreset('p_loose', 'Loose preset');
    await seedFolder('Roleplay', ['p_in_folder']);
    container.read(activePresetIdProvider.notifier).state = 'p_loose';

    await pumpList(tester);
    expect(find.text('Loose preset'), findsOneWidget);

    // The reveal is a once-per-open decision: a preset activated later must not
    // yank the list into its folder while the user is browsing.
    container.read(activePresetIdProvider.notifier).state = 'p_in_folder';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Loose preset'), findsOneWidget);
    expect(find.text('Filed preset'), findsNothing);
  });
}
