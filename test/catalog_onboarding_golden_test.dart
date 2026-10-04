import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/widgets/catalog_onboarding_sheet.dart';
import 'package:glaze_flutter/shared/theme/app_colors.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the catalog onboarding sheet to PNG, one image per step and flow.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/catalog_onboarding_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

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

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('ru')],
            path: 'assets/translations',
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('en'),
            child: Builder(
              builder: (context) => MaterialApp(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: AppTheme.dark(
                  const ThemePreset(id: 'default', name: 'Default'),
                  fontFamily: kInterFontFamily,
                ),
                home: Builder(
                  builder: (inner) => Scaffold(
                    backgroundColor: Colors.black,
                    body: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        decoration: BoxDecoration(
                          color: inner.cs.surface,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                        ),
                        child: const CatalogOnboardingSheet(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 4; i++) {
        await tester.pump(Duration.zero);
      }
      await tester.pump(const Duration(milliseconds: 400));
    });
    // Let the bundled provider logos decode and the async providers load.
    await settle(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await settle(tester);
  }

  testWidgets('catalog onboarding — JanitorAI flow', (tester) async {
    await pumpSheet(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/catalog_onboarding_1_intro.png'),
    );

    await tapText(tester, 'Next');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/catalog_onboarding_2_catalogs.png'),
    );

    await tapText(tester, 'Next');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/catalog_onboarding_3_janitor.png'),
    );

    await tapText(tester, 'Local');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/catalog_onboarding_3_janitor_local.png'),
    );

    await tapText(tester, 'Next');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/catalog_onboarding_4_janitor_login.png'),
    );
  }, skip: !_runGoldens);

  testWidgets('catalog onboarding — Chub flow', (tester) async {
    await pumpSheet(
      tester,
      prefs: {
        'gz_disabled_third_party_providers': <String>[
          'janitor',
          'janny',
          'datacat',
          'saucepan',
        ],
      },
    );

    await tapText(tester, 'Next');
    await tapText(tester, 'Next');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/catalog_onboarding_3_chub.png'),
    );
  }, skip: !_runGoldens);
}
