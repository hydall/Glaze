import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'helpers/pump_glaze_app.dart';
import 'helpers/test_container.dart';

/// Renders the theme preset list — at rest and scrolled under the header and
/// the tab strip — to PNG.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens test/theme_preset_screen_golden_test.dart
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

String _dataUrl(String asset) =>
    'data:image/jpeg;base64,${base64Encode(File(asset).readAsBytesSync())}';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
  });

  Future<ProviderContainer> pumpThemes(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = makeContainer(db);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.binding.setSurfaceSize(const Size(412, 892));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpGlazeApp(tester, container: container);

    await tester.runAsync(() async {
      final notifier = container.read(themeProvider.notifier);
      const covers = ['norimyn', 'mikrokot', 'fawnie', 'shino', 'renri'];
      for (var i = 0; i < covers.length; i++) {
        await notifier.importPreset(
          ThemePreset(
            id: 'custom_$i',
            name: 'Theme ${covers[i]}',
            author: 'Glaze',
            bgImage: _dataUrl('assets/presets/${covers[i]}.jpg'),
          ),
        );
      }
      await notifier.importPreset(
        const ThemePreset(id: 'custom_plain', name: 'Vivian'),
      );
    });

    container.read(routerProvider).go('/menu/themes');
    await pumpNavigation(tester);
    // Let the cover images decode for real.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    return container;
  }

  testWidgets('Theme presets, at rest', (tester) async {
    await pumpThemes(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/theme_presets_rest.png'),
    );
  }, skip: !_runGoldens);

  testWidgets('Theme presets, scrolled under the header', (tester) async {
    await pumpThemes(tester);
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/theme_presets_scrolled.png'),
    );
  }, skip: !_runGoldens);
}
