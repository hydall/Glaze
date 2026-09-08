import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/db/app_db.dart';

import 'package:glaze_flutter/features/chat_history/chat_history_screen.dart';
import 'package:glaze_flutter/features/character_list/character_list_screen.dart';
import 'package:glaze_flutter/features/tools/tools_screen.dart';
import 'package:glaze_flutter/features/menu/menu_screen.dart';
import 'package:glaze_flutter/features/settings/app_settings_screen.dart';
import 'package:glaze_flutter/features/settings/theme_preset_screen.dart';
import 'package:glaze_flutter/features/menu/about_screen.dart';
import 'package:glaze_flutter/features/menu/hall_of_fame_screen.dart';
import 'package:glaze_flutter/features/lorebooks/lorebook_list_screen.dart';
import 'package:glaze_flutter/features/lorebooks/lorebook_global_settings_screen.dart';
import 'package:glaze_flutter/features/lorebooks/embedding_settings_screen.dart';
import 'package:glaze_flutter/features/settings/api_settings_screen.dart';
import 'package:glaze_flutter/features/personas/persona_list_screen.dart';
import 'package:glaze_flutter/features/presets/preset_list_screen.dart';

import 'helpers/pump_glaze_app.dart';
import 'helpers/test_container.dart';

class ScreenEntry {
  final String path;
  final Type screenType;
  final String parentPath;
  final String description;

  const ScreenEntry({
    required this.path,
    required this.screenType,
    required this.parentPath,
    required this.description,
  });
}

const screenRegistry = <ScreenEntry>[
  ScreenEntry(
    path: '/',
    screenType: ChatHistoryScreen,
    parentPath: '/',
    description: 'Chat history (shell tab 0)',
  ),
  ScreenEntry(
    path: '/characters',
    screenType: CharacterListScreen,
    parentPath: '/characters',
    description: 'Character list (shell tab 1)',
  ),
  ScreenEntry(
    path: '/tools',
    screenType: ToolsScreen,
    parentPath: '/tools',
    description: 'Tools (shell tab 2)',
  ),
  ScreenEntry(
    path: '/menu',
    screenType: MenuScreen,
    parentPath: '/menu',
    description: 'Menu (shell tab 3)',
  ),
  ScreenEntry(
    path: '/menu/settings',
    screenType: AppSettingsScreen,
    parentPath: '/menu',
    description: 'App settings',
  ),
  ScreenEntry(
    path: '/menu/themes',
    screenType: ThemePresetScreen,
    parentPath: '/settings',
    description: 'Theme presets',
  ),
  ScreenEntry(
    path: '/menu/about',
    screenType: AboutScreen,
    parentPath: '/menu',
    description: 'About screen',
  ),
  ScreenEntry(
    path: '/menu/about/hall-of-fame',
    screenType: HallOfFameScreen,
    parentPath: '/menu/about',
    description: 'Hall of Fame screen',
  ),
  ScreenEntry(
    path: '/tools/api',
    screenType: ApiSettingsScreen,
    parentPath: '/tools',
    description: 'API settings',
  ),
  ScreenEntry(
    path: '/tools/personas',
    screenType: PersonaListScreen,
    parentPath: '/tools',
    description: 'Persona list',
  ),
  ScreenEntry(
    path: '/tools/presets',
    screenType: PresetListScreen,
    parentPath: '/tools',
    description: 'Preset list',
  ),
  ScreenEntry(
    path: '/tools/lorebooks',
    screenType: LorebookListScreen,
    parentPath: '/tools',
    description: 'Lorebook list',
  ),
  ScreenEntry(
    path: '/tools/lorebooks/settings',
    screenType: LorebookGlobalSettingsScreen,
    parentPath: '/tools/lorebooks',
    description: 'Lorebook global settings',
  ),
  ScreenEntry(
    path: '/tools/embeddings',
    screenType: EmbeddingSettingsScreen,
    parentPath: '/tools',
    description: 'Embedding settings',
  ),
];

/// Builds a fresh [ProviderContainer] with an in-memory DB and a **new**
/// GoRouter instance that has its own [GlobalKey<NavigatorState>]. See
/// `helpers/test_container.dart` for the implementation.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUpAll(initLocalizationOnce);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = makeContainer(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  GoRouter router() => container.read(routerProvider);

  testWidgets('App starts without black/red screen', (tester) async {
    await pumpGlazeApp(tester, container: container);

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
    expect(find.byType(ErrorWidget), findsNothing);
  });

  group('Screen navigation coverage', () {
    for (final entry in screenRegistry) {
      testWidgets('Navigate to ${entry.description} (${entry.path})', (
        tester,
      ) async {
        await pumpGlazeApp(tester, container: container);

        router().go(entry.path);
        await pumpNavigation(tester);

        expect(
          find.byType(entry.screenType, skipOffstage: false),
          findsWidgets,
          reason:
              'Expected to find ${entry.screenType} at ${entry.path}, '
              'but it was not found. If you added a new screen, '
              'update screenRegistry in navigation_smoke_test.dart.',
        );
      });
    }
  });

  testWidgets('Shell tabs are all reachable', (tester) async {
    await pumpGlazeApp(tester, container: container);

    final shellTabs = [
      ('/', 'Chat history', ChatHistoryScreen),
      ('/characters', 'Characters', CharacterListScreen),
      ('/tools', 'Tools', ToolsScreen),
      ('/menu', 'Menu', MenuScreen),
    ];

    for (final (path, label, screenType) in shellTabs) {
      router().go(path);
      await pumpNavigation(tester);

      expect(
        find.byType(screenType),
        findsWidgets,
        reason: 'Shell tab "$label" at $path did not render $screenType',
      );
    }
  });

  // Back navigation: sub-screens inside StatefulShellRoute branches.
  // These navigate within the shell (branch → branch), which GoRouter handles
  // without touching StatefulShellRoute's LabeledGlobalKey.
  final shellSubScreens = [
    (
      '/tools/api',
      '/tools',
      ApiSettingsScreen,
      ToolsScreen,
      'API settings → Tools',
    ),
    (
      '/tools/personas',
      '/tools',
      PersonaListScreen,
      ToolsScreen,
      'Persona list → Tools',
    ),
  ];

  for (final (subPath, parentPath, subType, parentType, label)
      in shellSubScreens) {
    testWidgets('Back navigation: $label', (tester) async {
      await pumpGlazeApp(tester, container: container);

      router().go(subPath);
      await pumpNavigation(tester);

      expect(
        find.byType(subType, skipOffstage: false),
        findsWidgets,
        reason: 'Failed to navigate to $subPath for $label test',
      );

      router().go(parentPath);
      await pumpNavigation(tester);

      expect(
        find.byType(parentType, skipOffstage: false),
        findsWidgets,
        reason:
            'Back navigation for "$label" failed: '
            'expected $parentType at $parentPath after going back',
      );
    });
  }

  // Back navigation: standalone routes → shell. Tested separately because
  // GoRouter's StatefulShellRoute uses a LabeledGlobalKey that can trigger a
  // duplicate-key assertion when the shell is rebuilt within one test after
  // multiple go() calls. We therefore verify only the sub-screen itself here;
  // shell reachability is already covered by "Shell tabs are all reachable".
  testWidgets('Back navigation: App settings renders', (tester) async {
    await pumpGlazeApp(tester, container: container);
    router().go('/menu/settings');
    await pumpNavigation(tester);
    expect(
      find.byType(AppSettingsScreen, skipOffstage: false),
      findsWidgets,
      reason: 'AppSettingsScreen at /menu/settings not found',
    );
  });

  testWidgets('Back navigation: About screen renders', (tester) async {
    await pumpGlazeApp(tester, container: container);
    router().go('/menu/about');
    await pumpNavigation(tester);
    expect(
      find.byType(AboutScreen, skipOffstage: false),
      findsWidgets,
      reason: 'AboutScreen at /menu/about not found',
    );
  });

  // Regression: pushing the lorebook global settings on top of the lorebook
  // list (which has live Tooltip OverlayPortals in its header actions) used to
  // crash during Scaffold layout — an OverlayPortal child reactivated mid
  // `_RenderLayoutBuilder.performLayout`. Presenting the screen as a
  // zero-transition GoRouter page avoids the animated reactivation path.
  testWidgets('Lorebook list → global settings pushes without layout crash', (
    tester,
  ) async {
    await pumpGlazeApp(tester, container: container);

    router().go('/tools/lorebooks');
    await pumpNavigation(tester);
    expect(find.byType(LorebookListScreen, skipOffstage: false), findsWidgets);

    unawaited(router().push('/tools/lorebooks/settings'));
    await pumpNavigation(tester);

    expect(
      find.byType(LorebookGlobalSettingsScreen, skipOffstage: false),
      findsWidgets,
      reason: 'Lorebook global settings did not render after push',
    );
    expect(tester.takeException(), isNull);
  });
}
