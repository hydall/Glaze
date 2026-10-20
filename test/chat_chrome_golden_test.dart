import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/chat/chat_drawer_controller.dart';
import 'package:glaze_flutter/features/chat/chrome/chat_chrome_channel.dart';
import 'package:glaze_flutter/features/chat/chrome/chat_composer_host.dart';
import 'package:glaze_flutter/features/chat/chrome/chrome_json.dart';
import 'package:glaze_flutter/features/chat/composer_pins_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_drawer_editing_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_drawer_tab.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_drawer_panel.dart';
import 'package:glaze_flutter/features/chat/widgets/magic_drawer_catalog.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_header.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_input_bar.dart';
import 'package:glaze_flutter/shared/theme/app_colors.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The chat chrome before and after it moved into the chat WebView, for
/// design review.
///
/// Renders the Flutter header and composer the chat used to draw to PNG, and
/// writes the state the new hosts send the page for the same scenes to
/// `test-results/chat_chrome/`, where `test/webview_js/tools/chrome_shots.mjs`
/// draws them in the real page and puts the two side by side.
///
///   GLAZE_GOLDENS=1 flutter test --update-goldens test/chat_chrome_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

const _size = Size(412, 860);
const _safeTop = 24.0;
const _safeBottom = 16.0;
const _out = 'test-results/chat_chrome';

Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

const _character = Character(id: 'c1', name: 'Seraphina', color: '#8E7CC3');

/// Stand-in for the messages under the chrome: bands of colour, so the glass
/// has something to blur. The page draws the same bands.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  static const colors = [
    Color(0xFF26323A),
    Color(0xFF6A3D5A),
    Color(0xFF2E4B3F),
    Color(0xFF8A6A2E),
    Color(0xFF3B3466),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 20; i++)
          Container(height: 43, color: colors[i % colors.length]),
      ],
    );
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await (FontLoader('MaterialIcons')..addFont(
          _font(
            '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
            '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ))
        .load();
    await (FontLoader(
      kInterFontFamily,
    )..addFont(_font('assets/fonts/InterVariable.ttf'))).load();
    Directory(_out).createSync(recursive: true);
  });

  Future<void> pumpApp(
    WidgetTester tester,
    Widget Function(BuildContext context, WidgetRef ref) builder,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = _size * 2;
    tester.view.padding = const FakeViewPadding(
      top: _safeTop * 2,
      bottom: _safeBottom * 2,
    );
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('ru')],
            path: 'assets/translations',
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('en'),
            child: Consumer(
              builder: (context, ref, _) => MaterialApp(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: AppTheme.dark(
                  ref.watch(themeProvider).activePreset,
                  fontFamily: kInterFontFamily,
                ),
                home: Material(
                  color: const Color(0xFF121212),
                  child: Consumer(
                    builder: (context, ref, _) => builder(context, ref),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  /// The chat as Flutter drew it: the header pill under the status bar and
  /// the composer over the bottom inset, on the bands.
  Widget flutterChat({
    required Widget composer,
    bool searching = false,
    double composerBottom = _safeBottom,
    Widget? drawer,
  }) {
    return Stack(
      children: [
        const Positioned.fill(child: _Backdrop()),
        if (drawer != null)
          Positioned(left: 0, right: 0, bottom: 0, height: 300, child: drawer),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Builder(
                builder: (context) => GlazeAppBar(
                  showBack: true,
                  onBack: () {},
                  // What the chat put in the bar while searching.
                  titleWidget: searching
                      ? TextField(
                          style: TextStyle(
                            color: context.cs.onSurface,
                            fontSize: 16,
                          ),
                          decoration: InputDecoration(
                            hintText: 'search_messages'.tr(),
                            hintStyle: TextStyle(
                              color: context.cs.onSurfaceVariant.withValues(
                                alpha: 0.5,
                              ),
                            ),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        )
                      : const ChatHeader(
                          character: _character,
                          sessionName: 'Session #3',
                        ),
                  actions: searching
                      ? const []
                      : [
                          IconButton(
                            icon: const Icon(Icons.search),
                            onPressed: () {},
                            color: context.cs.primary,
                          ),
                        ],
                ),
              ),
            ),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: composerBottom, child: composer),
      ],
    );
  }

  Future<void> dump(String name, Map<String, Object?> state) async {
    File(
      '$_out/state_$name.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(state));
  }

  for (final scene in _scenes) {
    testWidgets('before: Flutter chrome, ${scene.name}', (tester) async {
      await pumpApp(
        tester,
        (context, ref) => flutterChat(
          searching: scene.search,
          // The Flutter drawer needs the whole app behind it; the composer
          // is shown where it sat over an open one.
          composerBottom: scene.drawer ? 300 : _safeBottom,
          drawer: scene.drawer
              ? ProviderScope(
                  overrides: [
                    chatDrawerEditingProvider.overrideWith(
                      (ref) => scene.editing,
                    ),
                    chatDrawerTabProvider.overrideWith(
                      (ref) => ChatDrawerTab.values[scene.drawerTab],
                    ),
                  ],
                  child: ChatDrawerPanel(charId: 'c1', onClose: () {}),
                )
              : null,
          composer: ProviderScope(
            overrides: [
              chatDrawerEditingProvider.overrideWith((ref) => scene.editing),
            ],
            child: ChatInputBar(
              onSend: (_) async => true,
              isGenerating: scene.generating,
              onStop: scene.generating ? () {} : null,
              onMagicDrawer: () {},
              isDrawerOpen: scene.editing,
              initialDraft: scene.draft,
              blurViaWebView: false,
              charId: 'c1',
              showSearchControls: scene.search,
              searchMatchCount: scene.search ? 4 : 0,
              searchCurrentIndex: 1,
              onSearchNext: () {},
              onSearchPrev: () {},
              isSelectionMode: scene.selection,
              selectedCount: scene.selection ? 3 : 0,
              canDeleteSelected: scene.selection,
              onCancelSelection: () {},
              onHideSelected: () {},
              onDeleteSelected: () {},
            ),
          ),
        ),
      );
      if (scene.guidance) {
        await tester.tap(find.byIcon(Icons.north_east));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/chat_chrome_before_${scene.name}.png'),
      );
    }, skip: !_runGoldens);

    testWidgets('after: the state the page gets, ${scene.name}', (
      tester,
    ) async {
      final channel = ChatChromeChannel();
      final focus = ComposerFocus();
      addTearDown(focus.dispose);
      late Map<String, Object?> theme;
      await pumpApp(tester, (context, ref) {
        theme = chromeTheme(
          context,
          ref.watch(themeProvider).activePreset,
          batterySaver: false,
          desktop: false,
          fontFamily: kInterFontFamily,
        );
        return ProviderScope(
          overrides: [
            chatDrawerEditingProvider.overrideWith((ref) => scene.editing),
          ],
          child: SizedBox.expand(
            child: ChatComposerHost(
              channel: channel,
              composerFocus: focus,
              charId: 'c1',
              onSend: (_) async => true,
              isGenerating: scene.generating,
              onStop: scene.generating ? () {} : null,
              onMagicDrawer: () {},
              isDrawerOpen: scene.editing,
              initialDraft: scene.draft,
              showSearchControls: scene.search,
              searchMatchCount: scene.search ? 4 : 0,
              searchCurrentIndex: 1,
              onSearchNext: () {},
              onSearchPrev: () {},
              isSelectionMode: scene.selection,
              selectedCount: scene.selection ? 3 : 0,
              canDeleteSelected: scene.selection,
              onCancelSelection: () {},
              onHideSelected: () {},
              onDeleteSelected: () {},
            ),
          ),
        );
      });
      if (scene.guidance) {
        channel.debugIntent('pinTap', {'key': 'action:guidance'});
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      final sections = channel.debugSections;
      await dump(scene.name, {
        'theme': theme,
        'layout': {
          'safeTop': _safeTop,
          'safeBottom': _safeBottom,
          'inset': scene.drawer ? 300 : _safeBottom,
          'viewportH': _size.height,
          'keyboard': 0,
          'softKeyboard': false,
          'gutter': 0,
          'fades': false,
          'drawer': {
            'show': scene.drawer,
            'height': 300,
            'progress': scene.drawer ? 1 : 0,
          },
        },
        'header': {
          'show': true,
          'hidden': false,
          'flush': false,
          'radius': 20,
          'title': _character.name,
          'session': 'Session #3',
          'avatar': {
            'url': null,
            'color': chromeColor(const Color(0xFF8E7CC3)),
            'initial': 'S',
          },
          'search': {
            'kind': 'mobile',
            'open': scene.search,
            'hint': 'search_messages'.tr(),
          },
        },
        'composer': sections['composer'],
        'text': sections['text'],
        if (scene.drawer)
          'drawer': _drawerState(scene.drawerTab, scene.editing),
      });
      channel.dispose();
    }, skip: !_runGoldens);
  }
}

typedef _Scene = ({
  String name,
  String draft,
  bool guidance,
  bool generating,
  bool search,
  bool selection,
  bool editing,
  bool drawer,
  int drawerTab,
});

const _line = 'She looks up from the map, eyes narrowing.';

const List<_Scene> _scenes = [
  (
    name: 'idle',
    draft: '',
    guidance: false,
    generating: false,
    search: false,
    selection: false,
    editing: false,
    drawer: false,
    drawerTab: 0,
  ),
  (
    name: 'typed',
    draft: _line,
    guidance: false,
    generating: false,
    search: false,
    selection: false,
    editing: false,
    drawer: false,
    drawerTab: 0,
  ),
  (
    name: 'multiline',
    draft: '$_line\nThe wind picks up.\nSomewhere below, a bell rings twice.',
    guidance: false,
    generating: false,
    search: false,
    selection: false,
    editing: false,
    drawer: false,
    drawerTab: 0,
  ),
  (
    name: 'guidance',
    draft: '',
    guidance: true,
    generating: false,
    search: false,
    selection: false,
    editing: false,
    drawer: false,
    drawerTab: 0,
  ),
  (
    name: 'generating',
    draft: '',
    guidance: false,
    generating: true,
    search: false,
    selection: false,
    editing: false,
    drawer: false,
    drawerTab: 0,
  ),
  (
    name: 'search',
    draft: '',
    guidance: false,
    generating: false,
    search: true,
    selection: false,
    editing: false,
    drawer: false,
    drawerTab: 0,
  ),
  (
    name: 'selection',
    draft: '',
    guidance: false,
    generating: false,
    search: false,
    selection: true,
    editing: false,
    drawer: false,
    drawerTab: 0,
  ),
  (
    name: 'drawer_tools',
    draft: '',
    guidance: false,
    generating: false,
    search: false,
    selection: false,
    editing: false,
    drawer: true,
    drawerTab: 0,
  ),
  (
    name: 'drawer_actions',
    draft: '',
    guidance: false,
    generating: false,
    search: false,
    selection: false,
    editing: false,
    drawer: true,
    drawerTab: 1,
  ),
  (
    name: 'drawer_editing',
    draft: '',
    guidance: false,
    generating: false,
    search: false,
    selection: false,
    editing: true,
    drawer: true,
    drawerTab: 0,
  ),
];

/// The drawer as [ChatDrawerHost] describes it, for a chat with the shipped
/// layout and quick replies (the stats are made up: the host computes them
/// from the database).
Map<String, Object?> _drawerState(int tab, bool editing) {
  const statuses = {
    'inspector': '~4210/32000 tokens',
    'memory': '12 entries',
    'sessions': '3 sessions',
    'char-card': '1834 tokens',
    'lorebooks': '27 entries',
    'regex': '4 scripts',
    'api': 'Claude Sonnet',
    'presets': 'Default',
    'personas': 'Mira',
    'image-gen': 'Off',
    'authors-note': 'Empty',
    'glossary': null,
    'ext-blocks': 'No preset',
    'plugins': '0 of 0 on',
  };
  final tools = [
    for (final def in buildMagicDrawerItems())
      {
        'key': 'tool:${def.id}',
        'id': def.id,
        'kind': 'tool',
        'label': def.label,
        'icon': chromeIcon(def.icon),
        'status': statuses[def.id],
        'badge': 'delete',
      },
  ];
  final actions = [
    for (final action in ComposerAction.demotable)
      // The shipped row has these under the composer, so not in the tab.
      if (action != ComposerAction.translate &&
          !kDefaultComposerPins.contains(ComposerPin.action(action)))
        {
          'key': 'action:${action.id}',
          'id': action.id,
          'kind': 'action',
          'label': action.label,
          'icon': chromeIcon(action.icon, glyph: action.glyph),
          'badge': action.isInsert ? 'hide' : null,
          'insert': action.insertToken,
        },
    for (final (id, label, text) in [
      ('continue', 'Continue', 'Continue the response.'),
      ('tell-more', 'Tell more', 'Tell me more.'),
      ('what-next', 'What next?', 'What happens next?'),
      ('look-around', 'Look around', '*looks around*'),
    ])
      {
        'key': 'reply:$id',
        'id': id,
        'kind': 'reply',
        'label': label,
        'icon': chromeIcon(
          id == 'continue' ? Icons.keyboard_double_arrow_right : Icons.bolt,
        ),
        'status': id == 'continue' ? 'quick_reply_continue_hint'.tr() : text,
        'badge': id == 'continue' ? null : 'delete',
      },
  ];
  return {
    'show': true,
    'tab': tab,
    'editing': editing,
    'tabs': [
      {
        'label': 'drawer_tab_tools'.tr(),
        'icon': chromeIcon(Icons.auto_awesome),
      },
      {'label': 'drawer_tab_actions'.tr(), 'icon': chromeIcon(Icons.bolt)},
    ],
    'tools': {'loading': false, 'cards': tools, 'add': null},
    'actions': {
      'loading': false,
      'cards': actions,
      'add': {'label': 'action_add'.tr()},
    },
    'tips': {
      'edit': 'action_edit'.tr(),
      'done': 'btn_ok'.tr(),
      'delete': 'btn_delete'.tr(),
      'hide': 'composer_action_hide'.tr(),
    },
    'effects': true,
  };
}
