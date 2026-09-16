import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/preset_permissions.dart';
import 'package:glaze_flutter/features/extensions/screens/preset_editor/block_edit_dialog.dart';
import 'package:glaze_flutter/features/extensions/screens/preset_editor/sections/blocks_section.dart';
import 'package:glaze_flutter/features/extensions/screens/preset_editor/sections/permissions_section.dart';
import 'package:glaze_flutter/features/extensions/screens/preset_editor/sections/profiles_section.dart';

void main() {
  Future<AppDatabase> pumpSection(WidgetTester tester, Widget child) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDbProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pump();
    addTearDown(db.close);
    return db;
  }

  const preset = ExtensionPreset(
    id: 'preset-1',
    name: 'Test preset',
    blocks: [BlockConfig(id: 'block-1', name: 'Ledger')],
  );

  testWidgets('BlocksSection renders block list and add action', (
    tester,
  ) async {
    await pumpSection(tester, const BlocksSection(preset: preset));

    expect(find.text('blocks_section_header'), findsOneWidget);
    expect(find.text('Ledger'), findsOneWidget);
    expect(find.text('add_block'), findsOneWidget);
  });

  testWidgets('PermissionsSection renders capability switches', (tester) async {
    await pumpSection(tester, const PermissionsSection(preset: preset));

    // Grouped by scope rather than one flat list of twenty switches.
    expect(find.text('perm_group_chat_vars'), findsOneWidget);
    expect(find.text('perm_group_actions'), findsOneWidget);
    expect(find.text('perm_show_toast'), findsOneWidget);
    // The capability id the bridge checks stays next to its switch.
    expect(find.text('show_toast'), findsOneWidget);
    expect(
      find.byType(MenuSwitchItem),
      findsNWidgets(GlazeCapability.values.length),
    );
  });

  testWidgets('ProfilesSection renders one connection slot', (tester) async {
    await pumpSection(tester, const ProfilesSection(preset: preset));

    // The same connection/model pair the Agents tab and memory books use.
    expect(find.text('tab_api'), findsOneWidget);
    expect(find.text('studio_slot_api'), findsOneWidget);
    expect(find.text('studio_slot_model'), findsOneWidget);
    // Nothing is pinned, so both rows read as "follow the chat".
    expect(find.text('studio_slot_use_chat_api'), findsOneWidget);
    expect(find.text('studio_slot_model_auto'), findsOneWidget);
  });

  testWidgets('BlockEditDialog renders the default infoblock editor', (
    tester,
  ) async {
    // BlockEditDialog is now a SheetView, presented as a modal bottom sheet.
    // A tall surface keeps the whole lazily-built form on screen.
    tester.view.physicalSize = const Size(800, 5200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    BlockConfig? savedBlock;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDbProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => BlockEditDialog(
                    block: preset.blocks.first,
                    onSave: (block) => savedBlock = block,
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

    expect(find.text('block_edit_title'), findsOneWidget);
    expect(find.text('block_edit_name_label'), findsOneWidget);
    expect(find.text('block_type_infoblock'), findsOneWidget);
    expect(find.text('block_sec_context'), findsOneWidget);
    expect(find.text('block_ctx_use_main'), findsOneWidget);
    // Off by default, so the per-source toggles have a card of their own.
    expect(find.text('block_ctx_custom'), findsOneWidget);
    expect(find.text('block_ctx_character_card'), findsOneWidget);

    await tester.tap(find.text('block_ctx_use_main'));
    await tester.pumpAndSettle();
    // Reusing the main context leaves nothing to assemble.
    expect(find.text('block_ctx_custom'), findsNothing);

    final saveButton = find.widgetWithText(GlazePillButton, 'btn_save');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(savedBlock!.contextPolicy.useMainModelContext, isTrue);
    expect(savedBlock!.contextPolicy.legacyPromptSemantics, isFalse);
  });

  testWidgets('BlockEditDialog keeps numeric input across rebuilds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 5200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    BlockConfig? savedBlock;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDbProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: BlockEditDialog(
              block: preset.blocks.first.copyWith(contextMessageCount: 5),
              onSave: (block) => savedBlock = block,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // MenuFieldItem puts the label above the field rather than inside its
    // decoration, so the field is reached through the row that owns it.
    final contextField = find.descendant(
      of: find.ancestor(
        of: find.text('block_context_count_label'),
        matching: find.byType(MenuFieldItem),
      ),
      matching: find.byType(TextField),
    );
    await tester.enterText(contextField, '17');
    // Any rebuild will do; the switches are the cheapest one to trigger.
    await tester.tap(find.byType(MenuSwitchItem).first);
    await tester.pump();

    expect(tester.widget<TextField>(contextField).controller!.text, '17');

    final saveButton = find.widgetWithText(GlazePillButton, 'btn_save').last;
    await tester.ensureVisible(saveButton);
    await tester.pump();
    await tester.tap(saveButton);
    await tester.pump();
    expect(savedBlock?.contextMessageCount, 17);
  });
}
