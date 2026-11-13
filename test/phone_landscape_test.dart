import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_nav_bar.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';

import 'helpers/pump_glaze_app.dart';
import 'helpers/test_container.dart';

/// A phone turned sideways: the tabs move from the bottom bar to a side rail,
/// the content keeps clear of the cutout, and the layout stays the phone one.
///
/// Screenshots for design review:
///   GLAZE_GOLDENS=1 flutter test --update-goldens test/phone_landscape_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
  final iconsPath =
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (File(iconsPath).existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(_font(iconsPath))).load();
  }
  await (FontLoader(
    'Inter',
  )..addFont(_font('assets/fonts/InterVariable.ttf'))).load();
}

const _dpr = 2.0;

/// A 915x412 phone on its side, cutout on the left, gesture bar below.
const _landscape = Size(915, 412);
const _landscapePadding = FakeViewPadding(
  left: 32 * _dpr,
  top: 24 * _dpr,
  bottom: 12 * _dpr,
);
const _portrait = Size(412, 915);
const _portraitPadding = FakeViewPadding(top: 32 * _dpr, bottom: 16 * _dpr);

const _guidesSeen = <String, Object>{
  'guide_tabs_shown': true,
  'guide_chat_shown': true,
  'guide_characters_shown': true,
  'guide_tools_shown': true,
  'guide_more_shown': true,
  // Exercise the real layout rule, not the test helper's override.
  'gz_force_mobile_layout': false,
};

const _characters = [
  Character(
    id: 'c-1',
    name: 'Seraphina',
    color: '#8E7CC3',
    creator: 'Glaze',
    description: 'Guardian of the enchanted forest.',
    tags: ['fantasy', 'magic'],
  ),
  Character(
    id: 'c-2',
    name: 'Captain Vale',
    color: '#4F8FBA',
    creator: 'Glaze',
    description: 'Smuggler with a heart of gold.',
    tags: ['sci-fi'],
  ),
  Character(
    id: 'c-3',
    name: 'Mira',
    color: '#C27C5A',
    creator: 'Glaze',
    description: 'The quiet librarian of Station Nine.',
    tags: ['mystery'],
  ),
  Character(
    id: 'c-4',
    name: 'Juno',
    color: '#5AA37A',
    creator: 'Glaze',
    description: 'A detective who never sleeps.',
    tags: ['noir'],
  ),
  Character(
    id: 'c-5',
    name: 'Orrin',
    color: '#B8A04A',
    creator: 'Glaze',
    description: 'Retired dragon, now a baker.',
    tags: ['fantasy', 'cozy'],
  ),
];

Future<void> _seed(ProviderContainer container) async {
  final characters = container.read(characterRepoProvider);
  final chats = container.read(chatRepoProvider);
  for (final c in _characters) {
    await characters.put(c);
    await chats.put(
      ChatSession(id: 's-${c.id}', characterId: c.id, sessionIndex: 0),
    );
  }
}

Rect _pill(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(GlassNavRail),
        matching: find.byType(GlassSurface),
      )
      .first,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required Size size,
  required FakeViewPadding padding,
  bool railLeft = false,
}) async {
  tester.view.devicePixelRatio = _dpr;
  tester.view.physicalSize = size * _dpr;
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = makeContainer(db);
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await _seed(container);
  await pumpGlazeApp(
    tester,
    container: container,
    prefsSeed: {..._guidesSeen, 'gz_nav_rail_left': railLeft},
  );
  return container;
}

Future<void> _go(
  WidgetTester tester,
  ProviderContainer container,
  String location,
) async {
  container.read(routerProvider).go(location);
  await pumpNavigation(tester);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    // Always: the test font's square glyphs make the tab labels wide enough
    // to overflow the bottom bar.
    await _loadFonts();
  });

  testWidgets('sideways phone shows the side rail instead of the bottom bar', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      size: _landscape,
      padding: _landscapePadding,
    );
    await _go(tester, container, '/characters');

    expect(find.byType(GlassNavRail), findsOneWidget);
    expect(find.byType(GlassNavBar), findsNothing);
    // On the right by default, running the full height inside the safe area.
    final pill = _pill(tester);
    expect(pill.right, _landscape.width - kGlassNavRailMargin);
    expect(pill.top, 24 + kGlassNavRailMargin);
    expect(pill.bottom, _landscape.height - 12 - kGlassNavRailMargin);
    // The tabs spread along it: the first sits in the top quarter, the last
    // in the bottom one.
    final first = tester.getCenter(find.text('tab_dialogs'.tr()));
    final last = tester.getCenter(find.text('tab_more'.tr()));
    expect(first.dy, lessThan(pill.top + pill.height / 4));
    expect(last.dy, greaterThan(pill.bottom - pill.height / 4));

    // Tapping a rail tab switches branch.
    await tester.tap(find.text('tab_tools'.tr()));
    await pumpNavigation(tester);
    expect(
      container.read(routerProvider).routeInformationProvider.value.uri.path,
      '/tools',
    );
  });

  testWidgets('the rail can move to the left, clear of the cutout', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      size: _landscape,
      padding: _landscapePadding,
      railLeft: true,
    );
    await _go(tester, container, '/characters');

    final pill = _pill(tester);
    expect(pill.left, 32 + kGlassNavRailMargin);
    expect(pill.right, lessThan(_landscape.width / 2));
  });

  testWidgets('upright phone keeps the bottom bar', (tester) async {
    final container = await _pump(
      tester,
      size: _portrait,
      padding: _portraitPadding,
    );
    await _go(tester, container, '/characters');

    expect(find.byType(GlassNavBar), findsOneWidget);
    expect(find.byType(GlassNavRail), findsNothing);
  });

  group('screenshots', () {
    const shots = {
      'characters': '/characters',
      'chats': '/',
      'tools': '/tools',
      'more': '/menu',
      'settings': '/menu/settings',
    };
    for (final MapEntry(key: name, value: location) in shots.entries) {
      testWidgets('landscape $name', (tester) async {
        final container = await _pump(
          tester,
          size: _landscape,
          padding: _landscapePadding,
        );
        await _go(tester, container, location);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/landscape/landscape_$name.png'),
        );
      }, skip: !_runGoldens);
    }

    testWidgets('landscape characters, rail on the left', (tester) async {
      final container = await _pump(
        tester,
        size: _landscape,
        padding: _landscapePadding,
        railLeft: true,
      );
      await _go(tester, container, '/characters');
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/landscape/landscape_characters_rail_left.png'),
      );
    }, skip: !_runGoldens);

    testWidgets('portrait characters, for comparison', (tester) async {
      final container = await _pump(
        tester,
        size: _portrait,
        padding: _portraitPadding,
      );
      await _go(tester, container, '/characters');
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/landscape/portrait_characters.png'),
      );
    }, skip: !_runGoldens);
  });
}
