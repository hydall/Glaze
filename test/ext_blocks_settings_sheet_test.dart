import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/widgets/ext_blocks_settings_sheet.dart';
import 'package:glaze_flutter/shared/widgets/preset_switcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('context controls are not shared by the preset sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionPresetsProvider.notifier)
        .add(
          const ExtensionPreset(
            id: 'p1',
            name: 'Preset',
            blocks: [BlockConfig(id: 'b1', name: 'Ledger')],
          ),
        );
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p1'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ExtBlocksSettingsSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ledger'), findsOneWidget);
    expect(
      find.text('Передавать тот же контекст, что и в основную модель'),
      findsNothing,
    );
    expect(find.text('Настроить контекст блока'), findsNothing);
  });

  testWidgets('preset management hides behind the pill', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionPresetsProvider.notifier)
        .add(
          const ExtensionPreset(
            id: 'p1',
            name: 'Active preset',
            blocks: [BlockConfig(id: 'b1', name: 'Ledger')],
          ),
        );
    await container
        .read(extensionPresetsProvider.notifier)
        .add(const ExtensionPreset(id: 'p2', name: 'Other preset', blocks: []));
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p1'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ExtBlocksSettingsSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The panel itself carries the pill and the permissions row — creating,
    // importing and exporting a preset are no longer rows of their own.
    expect(find.byType(PresetPill), findsOneWidget);
    expect(find.text('Active preset'), findsOneWidget);
    expect(find.text('extblocks_permissions'), findsOneWidget);
    expect(find.text('extblocks_preset_create'), findsNothing);

    await tester.tap(find.byType(PresetPill));
    await tester.pumpAndSettle();

    // The switcher lists every preset plus "none", and carries creating and
    // importing in its header.
    expect(find.text('extblocks_preset_pick'), findsOneWidget);
    expect(find.text('Other preset'), findsOneWidget);
    expect(find.text('extblocks_preset_none'), findsOneWidget);
    expect(find.byTooltip('extblocks_preset_create'), findsOneWidget);
    expect(find.byTooltip('extblocks_preset_import'), findsOneWidget);
    // Export and delete sit on each preset row, two per preset.
    expect(find.byIcon(Icons.file_upload_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.delete_outline_rounded), findsNWidgets(2));
  });

  testWidgets('switcher row switches the active preset', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionPresetsProvider.notifier)
        .add(
          const ExtensionPreset(id: 'p1', name: 'Active preset', blocks: []),
        );
    await container
        .read(extensionPresetsProvider.notifier)
        .add(const ExtensionPreset(id: 'p2', name: 'Other preset', blocks: []));
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p1'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ExtBlocksSettingsSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PresetPill));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other preset'));
    await tester.pumpAndSettle();

    expect(container.read(extensionsSettingsProvider).activePresetId, 'p2');
    // Picking closes the switcher, and the pill follows.
    expect(find.text('extblocks_preset_pick'), findsNothing);
    expect(find.byType(PresetPill), findsOneWidget);
    expect(find.text('Other preset'), findsOneWidget);
  });
}
