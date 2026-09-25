import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/widgets/session_picker_sheet.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

const _charId = 'char-picker';

Future<ProviderContainer> _seed({required bool withSession}) async {
  SharedPreferences.setMockInitialValues({});
  ChatSessionService.clearCache();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [appDbProvider.overrideWithValue(db)],
  );
  addTearDown(() async {
    container.dispose();
    ChatSessionService.clearCache();
    await db.close();
  });

  await container
      .read(characterRepoProvider)
      .put(const Character(id: _charId, name: 'Alice'));
  if (withSession) {
    await container
        .read(chatRepoProvider)
        .put(
          const ChatSession(
            id: '${_charId}_0',
            characterId: _charId,
            sessionIndex: 0,
            messages: [
              ChatMessage(
                id: 'm1',
                role: 'user',
                content: 'Hello there',
                timestamp: 1,
              ),
            ],
          ),
        );
  }
  // Warm the list the picker reads, exactly like app start does.
  await container.read(chatHistoryProvider.future);
  return container;
}

/// Pumps the picker and taps the button that opens it, so the sheet is built on
/// the root navigator the way the app opens it.
Future<void> _openPicker(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.binding.setSurfaceSize(const Size(412, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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
              theme: AppTheme.dark(const ThemePreset(id: 'd', name: 'D')),
              home: Scaffold(
                body: Builder(
                  builder: (inner) => ElevatedButton(
                    onPressed: () =>
                        showSessionPickerSheet(inner, charId: _charId),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  });
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('an empty session list offers a centred create button', (
    tester,
  ) async {
    final container = await _seed(withSession: false);
    await _openPicker(tester, container);

    expect(find.text('btn_create'.tr()), findsOneWidget);
    // The header's add button is gone — the empty state is the only add
    // affordance, so the plus must not sit above it.
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('a populated list keeps the header add button', (tester) async {
    final container = await _seed(withSession: true);
    await _openPicker(tester, container);

    expect(find.text('btn_create'.tr()), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
    expect(
      find.text('session_name'.tr(namedArgs: {'id': '1'})),
      findsOneWidget,
    );
  });

  testWidgets('the centred button opens the new-session / import menu', (
    tester,
  ) async {
    final container = await _seed(withSession: false);
    await _openPicker(tester, container);

    await tester.tap(find.text('btn_create'.tr()));
    await tester.pumpAndSettle();

    // The menu title and its "New Session" item share a label.
    expect(find.text('action_new_session'.tr()), findsNWidgets(2));
    expect(find.text('action_import'.tr()), findsOneWidget);
  });
}
