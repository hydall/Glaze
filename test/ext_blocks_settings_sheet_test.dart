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
import 'package:glaze_flutter/features/extensions/screens/preset_editor/block_edit_dialog.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';
import 'package:glaze_flutter/shared/widgets/list_controls.dart';
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

  /// Two presets, the first active and holding one block, with External Blocks on.
  Future<ProviderContainer> pumpPanel(
    WidgetTester tester, {
    bool enabled = true,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
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
        .update(ExtensionsSettings(enabled: enabled, activePresetId: 'p1'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ExtBlocksSettingsSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the master switch lives in the header and gates the body', (
    tester,
  ) async {
    final container = await pumpPanel(tester, enabled: false);

    // Off: one line of explanation, and nothing to configure under it.
    expect(find.byType(GlazeSwitch), findsOneWidget);
    expect(find.text('extblocks_disabled_hint'), findsOneWidget);
    expect(find.byType(PresetPill), findsNothing);
    expect(find.text('Ledger'), findsNothing);

    await tester.tap(find.byType(GlazeSwitch));
    await tester.pumpAndSettle();

    expect(container.read(extensionsSettingsProvider).enabled, isTrue);
    expect(find.text('extblocks_disabled_hint'), findsNothing);
    expect(find.byType(PresetPill), findsOneWidget);
    expect(find.text('Ledger'), findsOneWidget);
  });

  testWidgets('the dropdown and permissions share the row above the cards', (
    tester,
  ) async {
    await pumpPanel(tester);

    expect(find.byType(PresetPill), findsOneWidget);
    expect(find.text('Active preset'), findsOneWidget);
    // Permissions ride at the right end of the pill's own row, labelled.
    final pill = tester.getRect(find.byType(PresetPill));
    final shield = tester.getRect(find.byType(GlazeActionChip));
    expect(find.text('extblocks_permissions'), findsOneWidget);
    expect(shield.center.dy, closeTo(pill.center.dy, 1));
    expect(shield.left, greaterThan(pill.right));
    // Hard against the same right edge as the cards under it.
    final api = tester.getRect(find.text('tab_api'));
    expect(shield.right, greaterThan(api.right));
    // Then the API card, then the blocks.
    final blocks = tester.getTopLeft(find.textContaining('(1)')).dy;
    expect(pill.top, lessThan(api.top));
    expect(api.top, lessThan(blocks));
    // One connection slot, the same pair the Agents tab and memory books show.
    expect(find.text('studio_slot_api'), findsOneWidget);
    expect(find.text('studio_slot_model'), findsOneWidget);
  });

  testWidgets('tapping a block opens that block, not a screen', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.text('Ledger'));
    await tester.pumpAndSettle();

    expect(find.byType(BlockEditDialog), findsOneWidget);
    expect(find.text('block_edit_name_label'), findsOneWidget);
  });

  testWidgets('the switcher sorts and keeps its actions in overflow menus', (
    tester,
  ) async {
    await pumpPanel(tester);

    await tester.tap(find.byType(PresetPill));
    await tester.pumpAndSettle();

    expect(find.text('extblocks_preset_pick'), findsOneWidget);
    expect(find.text('Other preset'), findsOneWidget);
    // The sort control and the drag toggle the API presets sheet has, and no
    // loose action buttons beside them.
    expect(find.byType(GlazeSortIconChip), findsOneWidget);
    expect(find.byType(GlazeReorderToggleButton), findsOneWidget);
    // One overflow button for the list, one per preset row.
    expect(find.byIcon(Icons.more_vert_rounded), findsNWidgets(3));

    // The list's menu: creating and importing.
    await tester.tap(find.byTooltip('preset_switcher_menu'));
    await tester.pumpAndSettle();
    expect(find.text('extblocks_preset_create'), findsOneWidget);
    expect(find.text('extblocks_preset_import'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('a preset row carries export and delete in its own menu', (
    tester,
  ) async {
    await pumpPanel(tester);

    await tester.tap(find.byType(PresetPill));
    await tester.pumpAndSettle();
    // The card list is built before the header, so the row menus come
    // first, in list order.
    await tester.tap(find.byIcon(Icons.more_vert_rounded).at(1));
    await tester.pumpAndSettle();

    expect(find.text('extblocks_preset_export'), findsOneWidget);
    expect(find.text('extblocks_preset_delete'), findsOneWidget);
  });

  testWidgets('switcher row switches the active preset', (tester) async {
    final container = await pumpPanel(tester);

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
