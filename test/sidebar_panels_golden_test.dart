import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/authors_note_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/prompt_inspector_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/session_picker_sheet.dart';
import 'package:glaze_flutter/features/extensions/widgets/ext_blocks_settings_sheet.dart';
import 'package:glaze_flutter/features/glossary/glossary_sheet.dart';
import 'package:glaze_flutter/features/image_gen/widgets/image_gen_sheet.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_tool_panels.dart';

import 'helpers/pump_glaze_app.dart';

/// Renders every tool the desktop right sidebar opens as a panel, in the full
/// desktop shell, to PNG for design review.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/sidebar_panels_golden_test.dart
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

ProviderContainer _desktopContainer(AppDatabase db) {
  final router = buildRouter(
    GlobalKey<NavigatorState>(),
    isForceMobile: () => false,
  );
  return ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      routerProvider.overrideWithValue(router),
    ],
  );
}

Future<void> _seed(ProviderContainer container) async {
  final personas = container.read(personaRepoProvider);
  await personas.put(const Persona(id: 'p-1', name: 'Alice'));
  await personas.put(const Persona(id: 'p-2', name: 'Bob'));
  final presets = container.read(presetRepoProvider);
  await presets.put(const Preset(id: 'pr-1', name: 'Storyteller'));
  await presets.put(const Preset(id: 'pr-2', name: 'Concise'));
  final lorebooks = container.read(lorebookRepoProvider);
  await lorebooks.put(const Lorebook(id: 'lb-1', name: 'Eldoria'));
  await lorebooks.put(const Lorebook(id: 'lb-2', name: 'Station Nine'));
  await container
      .read(apiConfigRepoProvider)
      .put(
        const ApiConfig(
          id: 'api-1',
          name: 'OpenRouter',
          endpoint: 'https://openrouter.ai/api/v1',
          model: 'anthropic/claude-sonnet-5',
        ),
      );
  await container
      .read(characterRepoProvider)
      .put(const Character(id: _charId, name: 'Mira'));
  await container
      .read(chatRepoProvider)
      .put(const ChatSession(id: 's-1', characterId: _charId, sessionIndex: 0));
  container.read(activePersonaIdProvider.notifier).state = 'p-1';
  container.read(activePresetIdProvider.notifier).state = 'pr-1';
}

final prefs = <String, Object>{
  'gz_force_mobile_layout': false,
  for (final key in const [
    'guide_chat_shown',
    'guide_characters_shown',
    'guide_tools_shown',
    'guide_more_shown',
  ])
    key: true,
  'gz_global_regex_scripts': jsonEncode([
    const PresetRegex(
      id: 'rx-1',
      name: 'Strip asterisks',
      regex: r'/\*/g',
    ).toJson(),
    const PresetRegex(
      id: 'rx-2',
      name: 'Trim OOC',
      regex: r'/\(OOC:.*?\)/g',
      disabled: true,
    ).toJson(),
  ]),
};

const _charId = 'c-1';

/// The Magic Drawer cards that open as a sidebar panel in the chat, built the
/// way `DrawerItemLauncher` builds them.
final Map<String, WidgetBuilder> _chatPanels = {
  'inspector': (_) => const PromptInspectorSheet(charId: _charId),
  'memory': (_) => const MemorySheet(charId: _charId),
  'sessions': (_) =>
      SessionPickerPanel(charId: _charId, onPicked: (_, _, _) async {}),
  'image-gen': (_) => const ImageGenSheet(charId: _charId),
  'authors-note': (_) => const AuthorsNoteSheet(charId: _charId),
  'glossary': (_) => const GlossarySheet(startExpanded: true),
  'ext-blocks': (_) => const ExtBlocksSettingsSheet(),
};

void main() {
  setUpAll(() async {
    await initLocalizationOnce();
    await _loadFonts();
  });

  Future<void> shoot(
    WidgetTester tester,
    SidebarPanel panel,
    String golden, {
    String location = '/characters',
  }) async {
    // Before anything reads the store: a provider that resolves
    // SharedPreferences early would keep the seedless instance.
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      ...prefs,
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = _desktopContainer(db);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await _seed(container);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // The chat's WebView has no platform implementation under test: its
    // build throws. Swallow that and paint the chat column a plain surface,
    // so the shot shows the sidebar rather than an error box.
    final onError = FlutterError.onError;
    final errorWidget = ErrorWidget.builder;
    if (location.startsWith('/chat/')) {
      FlutterError.onError = (details) {
        if (!details.toString().contains('ChatWebView')) onError?.call(details);
      };
      ErrorWidget.builder = (_) => const ColoredBox(color: Color(0xFF161616));
    }
    await pumpGlazeApp(tester, container: container, prefsSeed: prefs);
    container.read(routerProvider).go(location);
    await pumpNavigation(tester);

    container.read(rightSidebarPanelProvider.notifier).state = panel;
    await pumpNavigation(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$golden.png'),
    );
    // The chat leaves timers running (typing, autosave); let them fire on an
    // empty tree before the test ends.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    FlutterError.onError = onError;
    ErrorWidget.builder = errorWidget;
  }

  for (final tool in sidebarTools) {
    testWidgets(
      'sidebar panel: ${tool.id}',
      (tester) => shoot(tester, tool.panel, 'sidebar_panel_${tool.id}'),
      skip: !_runGoldens,
    );
  }

  for (final MapEntry(key: id, value: builder) in _chatPanels.entries) {
    testWidgets(
      'chat sidebar panel: $id',
      (tester) => shoot(
        tester,
        SidebarPanel(id: id, builder: builder),
        'sidebar_panel_chat_$id',
        location: '/chat/$_charId',
      ),
      skip: !_runGoldens,
    );
  }
}
