import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/chat/chat_search_delegate.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_header.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_header_search.dart';
import 'package:glaze_flutter/shared/theme/app_colors.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the desktop chat header search toggle to PNG for design review.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/chat_header_search_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

const _character = Character(id: 'c1', name: 'Seraphina', color: '#8E7CC3');

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
  });

  Future<ChatSearchDelegate> pump(
    WidgetTester tester, {
    required bool inTitleBar,
  }) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = Size(760 * 2, (inTitleBar ? 36 : 56) * 2);
    addTearDown(tester.view.reset);
    final search = ChatSearchDelegate();
    addTearDown(search.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
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
                  builder: (context) => Material(
                    color: context.cs.surface,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(Icons.arrow_back, color: context.cs.onSurface),
                          const SizedBox(width: 12),
                          // The title bar centres its middle slot.
                          if (inTitleBar)
                            Expanded(
                              child: Center(
                                child: DesktopChatHeaderSearch(
                                  search: search,
                                  charId: 'c1',
                                  inTitleBar: true,
                                  headerBuilder: (toggle) => ChatHeader(
                                    character: _character,
                                    sessionName: 'Session #3',
                                    compact: true,
                                    trailing: Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: toggle,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            Expanded(
                              child: DesktopChatHeaderSearch(
                                search: search,
                                charId: 'c1',
                                headerBuilder: (toggle) => ChatHeader(
                                  character: _character,
                                  sessionName: 'Session #3',
                                  trailing: Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: toggle,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    return search;
  }

  Future<void> shoot(String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/chat_header_search_$name.png'),
  );

  for (final inTitleBar in [false, true]) {
    final tag = inTitleBar ? 'titlebar' : 'header';
    testWidgets('$tag: toggle opens and closes the field', (tester) async {
      final search = await pump(tester, inTitleBar: inTitleBar);
      await shoot('${tag}_closed');

      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pump();
      expect(search.inlineOpen, isTrue);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<Visibility>(find.byType(Visibility).first).visible,
        isFalse,
      );
      // The field takes the character block's exact place.
      expect(
        tester.getSize(find.byType(Stack).last).width,
        tester.getSize(find.byType(ChatHeader)).width,
      );
      // Placeholder, typed text and the cross share one centre line.
      double centreY(Finder f) => tester.getCenter(f).dy;
      final fieldBox = find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(DecoratedBox),
      );
      final boxY = centreY(fieldBox.first);
      expect(centreY(find.text('Поиск сообщений')), closeTo(boxY, 0.5));
      expect(centreY(find.byType(EditableText)), closeTo(boxY, 0.5));
      expect(centreY(find.byIcon(Icons.close_rounded)), closeTo(boxY, 0.5));
      await shoot('${tag}_open');

      search.searchController.text = 'dragon';
      await tester.pump();
      await shoot('${tag}_query');

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(search.inlineOpen, isFalse);
      expect(search.searchController.text, isEmpty);
      expect(
        tester.widget<Visibility>(find.byType(Visibility).first).visible,
        isTrue,
      );
    }, skip: !_runGoldens);
  }
}
