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
}
