import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
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

    expect(find.text('Разрешения (capabilities)'), findsOneWidget);
    expect(find.text('show_toast'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsWidgets);
  });

  testWidgets('ProfilesSection renders generateText profile rows', (
    tester,
  ) async {
    await pumpSection(tester, const ProfilesSection(preset: preset));

    expect(find.text('Профили подключения (generateText)'), findsOneWidget);
    expect(find.text('big'), findsOneWidget);
    expect(find.text('medium'), findsOneWidget);
    expect(find.text('small'), findsOneWidget);
  });

  testWidgets('BlockEditDialog renders the default infoblock editor', (
    tester,
  ) async {
    // BlockEditDialog is now a SheetView, presented as a modal bottom sheet.
    // A tall surface keeps the whole lazily-built form on screen.
    tester.view.physicalSize = const Size(800, 3200);
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
    expect(find.text('Контекст блока'), findsOneWidget);
    expect(
      find.text('Передавать тот же контекст, что и в основную модель'),
      findsOneWidget,
    );
    expect(find.text('Настроить контекст блока'), findsOneWidget);

    await tester.tap(
      find.text('Передавать тот же контекст, что и в основную модель'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'btn_save'));
    await tester.pumpAndSettle();

    expect(savedBlock!.contextPolicy.useMainModelContext, isTrue);
    expect(savedBlock!.contextPolicy.legacyPromptSemantics, isFalse);
  });

  testWidgets('BlockEditDialog keeps numeric input across rebuilds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3200);
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

    final contextField = find.widgetWithText(
      TextField,
      'block_context_count_label',
    );
    await tester.enterText(contextField, '17');
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();

    expect(tester.widget<TextField>(contextField).controller!.text, '17');

    await tester.tap(find.widgetWithText(FilledButton, 'btn_save').last);
    await tester.pump();
    expect(savedBlock?.contextMessageCount, 17);
  });
}
