import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_extractor.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_public_lorebook.dart';
import 'package:glaze_flutter/features/catalog/widgets/janitor_extraction_settings_sheet.dart';
import 'package:glaze_flutter/features/catalog/widgets/janitor_lorebook_capture_sheet.dart';
import 'package:glaze_flutter/features/catalog/widgets/janitor_lorebooks_tab.dart';
import 'package:glaze_flutter/features/catalog/widgets/third_party_providers_screen.dart';
import 'package:glaze_flutter/features/character_list/character_detail_screen.dart';
import 'package:glaze_flutter/features/studio/widgets/studio_slots_tab.dart';
import 'package:glaze_flutter/shared/theme/app_colors.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the "Character + lorebooks" import flow and the lorebook build
/// settings to PNG for design review.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/lorebook_capture_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

Future<void> _loadFonts() async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      _font(
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    );
  await icons.load();
  final inter = FontLoader('Inter')
    ..addFont(_font('assets/fonts/InterVariable.ttf'));
  await inter.load();
}

const _meta = <String, dynamic>{
  'name': 'Mira',
  'description': 'A courier in the floating city of Aster.',
  'scenario': 'You meet Mira at the docks of Aster.',
  'first_message': 'Mira waves from the pier.',
  'scripts': [
    {'id': 'lb-closed', 'title': 'Aster — city lore', 'type': 'lorebook'},
  ],
};

const _args = JanitorLorebookArgs(
  characterId: 'jan-1',
  sourceUrl: 'https://janitorai.com/characters/jan-1',
  meta: _meta,
);

final _capture = ExtractionResult(
  characterId: 'jan-1',
  sourceUrl: _args.sourceUrl,
  character: DownloadedCharacter(charData: CharacterData(name: 'Mira')),
  lorebookText: List.filled(
    40,
    'Aster is a floating city held up by old engines.',
  ).join('\n\n'),
  entryBlockCount: 40,
  cardContext: 'Mira is a courier who knows every roof in Aster.',
  catalogContext: 'Name: Mira',
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
    // One closed book, one public: the proxy that would fetch them has no
    // platform here.
    debugFetchPublicLorebooks = (_) async => const [
      PublicLorebook(
        id: 'lb-closed',
        title: 'Aster — city lore',
        description: 'Districts, guilds and the engines under the city.',
      ),
      PublicLorebook(
        id: 'lb-public',
        title: 'Mira — side characters',
        accessible: true,
        entryCount: 12,
      ),
    ];
  });
  tearDownAll(() => debugFetchPublicLorebooks = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(430, 932),
    bool sheet = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'janitorSource': 'local',
      'gz_janitor_user_name': 'mira_fan',
      'guide_lorebook_capture_shown': true,
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDbProvider.overrideWithValue(db)],
          child: EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('ru')],
            path: 'assets/translations',
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('ru'),
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
                    body: sheet
                        ? Container(
                            margin: const EdgeInsets.only(top: 40),
                            decoration: BoxDecoration(
                              color: inner.cs.surface,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(24),
                              ),
                            ),
                            child: child,
                          )
                        : child,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    });
    await settle(tester);
  }

  Future<void> shoot(WidgetTester tester, String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );

  testWidgets('1 — sheet opens on the running character import', (
    tester,
  ) async {
    final phase = ValueNotifier<String?>('triggering (card)');
    final never = Completer<JanitorImportedCharacter>();
    await pump(
      tester,
      JanitorLorebookCapture(
        args: _args,
        pendingCharacter: JanitorPendingCharacter(
          phase: phase,
          result: never.future,
        ),
      ),
    );
    await shoot(tester, 'lorebook_capture_1_importing');
  }, skip: !_runGoldens);

  testWidgets('2 — collect options once the character landed', (tester) async {
    final phase = ValueNotifier<String?>(null);
    await pump(
      tester,
      JanitorLorebookCapture(
        args: _args,
        pendingCharacter: JanitorPendingCharacter(
          phase: phase,
          result: Future.value(
            JanitorImportedCharacter(characterId: 'c-1', extraction: _capture),
          ),
        ),
      ),
      size: const Size(430, 1500),
    );
    await shoot(tester, 'lorebook_capture_2_collect');
  }, skip: !_runGoldens);

  testWidgets('3 — capture sheet settings', (tester) async {
    await pump(
      tester,
      const JanitorExtractionSettingsSheet(),
      size: const Size(430, 1300),
    );
    await shoot(tester, 'lorebook_capture_3_settings');
  }, skip: !_runGoldens);

  testWidgets('4 — agents tab', (tester) async {
    await pump(
      tester,
      StudioSlotsTab(controller: ScrollController()),
      size: const Size(430, 2200),
      sheet: false,
    );
    await shoot(tester, 'lorebook_capture_4_agents');
  }, skip: !_runGoldens);

  testWidgets('5 — content providers', (tester) async {
    await pump(
      tester,
      const ThirdPartyProvidersScreen(),
      size: const Size(430, 2600),
      sheet: false,
    );
    await shoot(tester, 'lorebook_capture_5_providers');
    await tester.tap(find.text('Сборка лорбуков'));
    await settle(tester);
    await shoot(tester, 'lorebook_capture_5b_providers_expanded');
  }, skip: !_runGoldens);

  testWidgets('6 — import FAB while the character imports', (tester) async {
    await pump(
      tester,
      const CharacterDetailScreen(
        charId: 'preview:jan-1',
        previewCharacter: Character(id: 'preview:jan-1', name: 'Mira'),
        importing: true,
        importPhase: 'configuring proxy',
      ),
    );
    await shoot(tester, 'lorebook_capture_6_fab');
    // The detail screen leaves timers running; let them fire on an empty tree.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
  }, skip: !_runGoldens);
}
