import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

import 'helpers/pump_glaze_app.dart';
import 'helpers/test_container.dart';

/// Renders the reworked, Windows-Phone-style Tools screen to PNG.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens test/tools_screen_golden_test.dart
Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

Future<void> _loadFonts() async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      _font(
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/fl/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    );
  await icons.load();
  final loader = FontLoader('Inter')
    ..addFont(
      File('assets/fonts/InterVariable.ttf').readAsBytes().then(
        (bytes) => ByteData.view(Uint8List.fromList(bytes).buffer),
      ),
    );
  await loader.load();
}

final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

Future<AppDatabase> _seedDb(ProviderContainer container) async {
  await container.read(personaRepoProvider).put(
    const Persona(id: 'p-demo', name: 'Alice'),
  );
  await container.read(presetRepoProvider).put(
    const Preset(id: 'pr-demo', name: 'Storyteller'),
  );
  container.read(activePersonaIdProvider.notifier).state = 'p-demo';
  container.read(activePresetIdProvider.notifier).state = 'pr-demo';
  return container.read(appDbProvider);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
  });

  Future<ProviderContainer> pumpTools(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = makeContainer(db);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await _seedDb(container);
    await tester.binding.setSurfaceSize(const Size(412, 892));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpGlazeApp(tester, container: container);
    return container;
  }

  testWidgets('Tools screen, default layout', (tester) async {
    final container = await pumpTools(tester);
    container.read(routerProvider).go('/tools');
    await pumpNavigation(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/tools_screen.png'),
    );
  }, skip: !_runGoldens);

  testWidgets('Tools screen, edit mode', (tester) async {
    final container = await pumpTools(tester);
    container.read(routerProvider).go('/tools');
    await pumpNavigation(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/tools_screen_edit.png'),
    );
  }, skip: !_runGoldens);
}
