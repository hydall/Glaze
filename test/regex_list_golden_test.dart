import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/folder.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/folder_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_tool_panels.dart';
import 'package:glaze_flutter/shared/widgets/list_controls.dart';

import 'helpers/pump_glaze_app.dart';

/// Renders the regex list — the preset's scripts as a folder with folders of
/// its own, global folders, multi-select, moving scripts into a folder and the
/// filter sheet — on a phone and in the desktop sidebar, to PNG for design
/// review.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/regex_list_golden_test.dart
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

PresetRegex _rx(String id, String name, String regex, {bool off = false}) =>
    PresetRegex(id: id, name: name, regex: regex, disabled: off);

final _prefs = <String, Object>{
  for (final key in const [
    'guide_tabs_shown',
    'guide_chat_shown',
    'guide_characters_shown',
    'guide_tools_shown',
    'guide_more_shown',
    'guide_api_shown',
    'guide_presets_shown',
    'guide_personas_shown',
    'guide_desktop_shown',
    'guide_lorebook_capture_shown',
  ])
    key: true,
  'gz_global_regex_scripts': jsonEncode([
    for (final r in [
      _rx('g1', 'Strip asterisks', r'/\*/g'),
      _rx('g2', 'Trim OOC', r'/\(OOC:.*?\)/g', off: true),
      _rx('g3', 'Hide thinking', r'/<think>[\s\S]*?<\/think>/g'),
      _rx('g4', 'Status bar card', r'/\{(\d+):(\d+)\|([^}]+)\}/g'),
      _rx('g5', 'Fix quotes', r'/[«»]/g'),
    ])
      r.toJson(),
  ]),
};

Future<ProviderContainer> _container(
  WidgetTester tester, {
  required bool desktop,
}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      routerProvider.overrideWithValue(
        buildRouter(GlobalKey<NavigatorState>(), isForceMobile: () => !desktop),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await container
      .read(presetRepoProvider)
      .put(
        Preset(
          id: 'pr-1',
          name: 'Shino',
          regexFolders: const [PresetRegexFolder(id: 'pf1', name: 'Styling')],
          regexes: [
            _rx('p1', 'Narration colour', r'/\*(.+?)\*/g'),
            _rx('p2', 'Dialogue quotes', r'/"(.+?)"/g'),
            _rx('p3', 'Scene break', r'/^---$/gm', off: true),
            _rx('p4', 'Bold names', r'/\b([A-Z]\w+):/g').copyWith(
              folderId: 'pf1',
            ),
            _rx('p5', 'Em dashes', r'/--/g').copyWith(folderId: 'pf1'),
          ],
        ),
      );
  container.read(activePresetIdProvider.notifier).state = 'pr-1';
  final folders = container.read(folderRepoProvider);
  final folder = await folders.create(
    domain: FolderDomain.regex,
    name: 'Formatting',
  );
  await folders.addMember(folder.id, 'g4');
  await folders.addMember(folder.id, 'g5');
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shoot(WidgetTester tester, String name) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('goldens/regex_list_$name.png'),
);

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 30));
}

void main() {
  setUpAll(() async {
    await initLocalizationOnce();
    await _loadFonts();
  });

  testWidgets('phone', (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      ..._prefs,
    });
    final container = await _container(tester, desktop: false);
    await tester.binding.setSurfaceSize(const Size(412, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpGlazeApp(tester, container: container, prefsSeed: _prefs);
    container.read(routerProvider).go('/tools/regex');
    await pumpNavigation(tester);
    await _settle(tester);
    await _shoot(tester, 'phone_root');

    await tester.tap(find.text('Shino'));
    await _settle(tester);
    await _shoot(tester, 'phone_preset');

    await tester.longPress(find.text('Narration colour'));
    await _settle(tester);
    await tester.tap(find.text('Dialogue quotes'));
    await _settle(tester);
    await _shoot(tester, 'phone_selecting');

    await tester.tap(find.byIcon(Icons.more_horiz_rounded).last);
    await _settle(tester);
    await _shoot(tester, 'phone_selection_actions');
    await tester.tap(find.text('Move to folder'));
    await _settle(tester);
    await _shoot(tester, 'phone_move_to_folder');
    await tester.tapAt(const Offset(200, 40));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await _settle(tester);

    await tester.tap(find.byType(GlazeFilterIconButton));
    await _settle(tester);
    await _shoot(tester, 'phone_filter');
    await tester.binding.handlePopRoute();
    await _settle(tester);

    await tester.tap(find.text('Styling'));
    await _settle(tester);
    await _shoot(tester, 'phone_preset_folder');

    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.tap(find.text('Formatting'));
    await _settle(tester);
    await _shoot(tester, 'phone_global_folder');
    await _finish(tester);
  }, skip: !_runGoldens);

  testWidgets('desktop sidebar', (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'gz_force_mobile_layout': false,
      ..._prefs,
    });
    final container = await _container(tester, desktop: true);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpGlazeApp(
      tester,
      container: container,
      prefsSeed: {..._prefs, 'gz_force_mobile_layout': false},
    );
    // The Tools hub the sidebar shows before a panel opens overflows its
    // header by a fraction of a pixel at this width (on nightly, for every
    // panel in sidebar_panels_golden_test.dart too). Not this screen's row —
    // let that one report through until the panel is up.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.toString().contains('A RenderFlex overflowed')) {
        onError?.call(details);
      }
    };
    container.read(routerProvider).go('/characters');
    await pumpNavigation(tester);
    container.read(rightSidebarPanelProvider.notifier).state =
        sidebarToolPanel('regex');
    await pumpNavigation(tester);
    FlutterError.onError = onError;
    await _settle(tester);
    await _shoot(tester, 'desktop_root');

    await tester.tap(find.text('Shino'));
    await _settle(tester);
    await tester.longPress(find.text('Narration colour'));
    await _settle(tester);
    await tester.tap(find.text('Scene break'));
    await _settle(tester);
    await _shoot(tester, 'desktop_selecting');
    await _finish(tester);
  }, skip: !_runGoldens);
}
