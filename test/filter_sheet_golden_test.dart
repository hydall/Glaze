import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_http.dart';
import 'package:glaze_flutter/features/catalog/services/chub_provider.dart';
import 'package:glaze_flutter/features/catalog/widgets/catalog_filter_sheet.dart';
import 'package:glaze_flutter/features/character_list/widgets/character_filter_sheet.dart';
import 'package:glaze_flutter/features/presets/widgets/preset_filter_sheet.dart';
import 'package:glaze_flutter/shared/theme/app_colors.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glaze_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the filter sheets to PNG for design review.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/filter_sheet_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

const _chubTags = [
  'female', 'male', 'oc', 'fantasy', 'romance', 'anime', 'roleplay',
  'english', 'scenario', 'submissive', 'dominant', 'monster girl', 'furry',
  'drama', 'comedy', 'horror', 'sci-fi', 'game characters', 'villain',
  'love', 'tsundere', 'yandere', 'kuudere', 'dandere', 'milf', 'mommy',
  'elf', 'demon', 'vampire', 'werewolf', 'angel', 'goddess', 'robot',
  'android', 'cyberpunk', 'post-apocalyptic', 'medieval', 'modern',
  'school', 'office', 'military', 'magic', 'adventure', 'mystery',
  'slice of life', 'action', 'historical', 'western', 'pirate', 'ninja',
  'samurai', 'knight', 'princess', 'queen', 'king', 'maid', 'butler',
  'teacher', 'student', 'nurse', 'doctor', 'detective', 'assassin',
  'mercenary', 'witch', 'wizard', 'necromancer', 'dragon', 'kemonomimi',
  'catgirl', 'foxgirl', 'bunny girl', 'tomboy', 'gyaru', 'shy', 'bully',
  'rivals', 'enemies to lovers', 'friends to lovers', 'childhood friend',
  'roommate', 'neighbor', 'boss', 'coworker', 'stepfamily', 'multiple',
  'rpg', 'simulator', 'narrator', 'utility', 'non-english', 'japanese',
  'chinese', 'korean', 'russian', 'spanish', 'genshin impact',
  'honkai star rail', 'blue archive', 'pokemon', 'naruto', 'one piece',
  'my hero academia', 'jujutsu kaisen', 'chainsaw man', 'vtuber',
  'hololive', 'touhou', 'league of legends', 'overwatch', 'fnaf',
];

class _ChubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    String body;
    if (options.path.endsWith('/tags') && options.method == 'POST') {
      final q = (jsonDecode(options.data as String) as Map)['search'] as String?;
      // The unfiltered index only hands back the head of the list, so a
      // search can surface tags the grid does not hold.
      final names = q == null
          ? _chubTags.take(60).toList()
          : _chubTags.where((t) => t.contains(q.toLowerCase())).toList();
      body = jsonEncode({
        'count': names.length,
        'tags': [
          for (var i = 0; i < names.length; i++)
            {
              'id': i + 1,
              'name': names[i],
              'non_private_projects_count': 100000 - i * 500,
            },
        ],
      });
    } else {
      // Legacy sampling path: one page of characters carrying the topics.
      body = jsonEncode({
        'nodes': [
          for (var i = 0; i < 60; i++)
            {
              'fullPath': 'u/c$i',
              'topics': [
                for (var j = 0; j < 8; j++)
                  _chubTags[(i * 3 + j * 7) % _chubTags.length],
              ],
            },
        ],
      });
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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
  final loader = FontLoader('Inter')
    ..addFont(
      File('assets/fonts/InterVariable.ttf').readAsBytes().then(
        (bytes) => ByteData.view(Uint8List.fromList(bytes).buffer),
      ),
    );
  await loader.load();
}

/// The sheet's own list — single-line text fields carry horizontal
/// Scrollables of their own, so match on the axis.
final _sheetList = find.byWidgetPredicate(
  (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
).last;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
    setCatalogHttpAdapter(_ChubAdapter());
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester tester,
    WidgetBuilder sheet, {
    String locale = 'ru',
  }) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(430 * 2, 932 * 2);
    addTearDown(tester.view.reset);
    late BuildContext host;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('ru')],
            path: 'assets/translations',
            fallbackLocale: const Locale('en'),
            startLocale: Locale(locale),
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
                  builder: (inner) {
                    host = inner;
                    return Scaffold(backgroundColor: inner.cs.surface);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    unawaited(showGlazeSheet<void>(
      context: host,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: sheet,
    ));
    await settle(tester);
  }

  Future<void> shoot(String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/filter_sheet_$name.png'),
  );

  Future<void> scrollBy(WidgetTester tester, double dy) async {
    await tester.drag(_sheetList, Offset(0, -dy));
    await settle(tester);
  }

  testWidgets('chub filters', (tester) async {
    resetChubTagCache();
    await open(
      tester,
      (_) => CatalogFilterSheet(
        filters: const CatalogFilters(
          tagNames: ['fantasy', 'elf'],
          requireLore: true,
        ),
        provider: CatalogProvider.chub,
        onApply: (_) {},
      ),
    );
    await shoot('chub_top');

    final showAll = find.textContaining('Показать все');
    await tester.scrollUntilVisible(
      showAll,
      300,
      scrollable: _sheetList,
    );
    await settle(tester);
    await scrollBy(tester, 200);
    await shoot('chub_tags');

    await tester.tap(showAll);
    await settle(tester);
    await scrollBy(tester, 900);
    await shoot('chub_tags_expanded');

    await tester.ensureVisible(find.byType(TextField).last);
    await scrollBy(tester, 150);

    await tester.enterText(find.byType(TextField).last, 'gen');
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    await shoot('chub_search');

    await tester.enterText(find.byType(TextField).last, 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    await shoot('chub_search_custom');
  }, skip: !_runGoldens);

  testWidgets('chub filters, nothing set', (tester) async {
    await open(
      tester,
      (_) => CatalogFilterSheet(
        filters: const CatalogFilters(),
        provider: CatalogProvider.chub,
        onApply: (_) {},
      ),
    );
    await shoot('chub_default');
  }, skip: !_runGoldens);

  testWidgets('character filters', (tester) async {
    await open(
      tester,
      (_) => CharacterFilterSheet(
        filters: const CharacterListFilters(),
        allTags: _chubTags.take(70).toList(),
        onApply: (_) {},
      ),
    );
    await shoot('characters');
  }, skip: !_runGoldens);

  testWidgets('preset filters', (tester) async {
    await open(
      tester,
      (_) => PresetFilterSheet(
        filters: const PresetListFilters(),
        onApply: (_) {},
      ),
    );
    await shoot('presets');
  }, skip: !_runGoldens);
}
