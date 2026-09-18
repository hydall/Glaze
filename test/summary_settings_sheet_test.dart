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
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/summary_settings_sheet.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

/// The Summary tab used to be the text plus every setting the summary has, with
/// the master switch promoted into the sheet header as a bare `Switch`. It is
/// the text and the Summarize button now; the settings live behind the header's
/// button, as the Memory Books tab's do.
const _charId = 'char-summary';
const _sessionId = 'session-summary';

Future<ProviderContainer> _seed() async {
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
      .put(Character(id: _charId, name: 'Alice'));
  await container
      .read(chatRepoProvider)
      .put(
        const ChatSession(
          id: _sessionId,
          characterId: _charId,
          sessionIndex: 0,
          messages: [
            ChatMessage(id: 'm1', role: 'user', content: 'Hello', timestamp: 1),
          ],
        ),
      );
  await container
      .read(summaryServiceProvider)
      .setSummary(
        sessionId: _sessionId,
        content: 'They reached the pass after dark.',
        messageCount: 1,
      );
  await container.read(chatProvider(_charId).future);
  return container;
}

Future<void> _openSheet(
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
          startLocale: const Locale('ru'),
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: AppTheme.dark(const ThemePreset(id: 'd', name: 'D')),
              home: const Scaffold(
                body: MemorySheet(
                  charId: _charId,
                  initialTab: MemoryTab.summary,
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
}

/// Lets the sheet's own load finish: it reads the summary, the prefs and the
/// preset list, none of which complete under the fake clock alone, and it
/// shows a spinner until they do — so `pumpAndSettle` would never settle.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 8; round++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.tune_rounded));
  await tester.pump();
  await _settle(tester);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('the tab is the summary and one Glaze button', (tester) async {
    final container = await _seed();
    await _openSheet(tester, container);

    expect(find.text('They reached the pass after dark.'), findsOneWidget);
    // The kit's button, not a Material one in a hand-picked blue.
    expect(find.byType(GlazeActionButton), findsOneWidget);
    expect(find.text('btn_auto_summary'.tr()), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    // The settings are not in the tab any more…
    expect(find.text('summary_prompt_label'.tr()), findsNothing);
    expect(find.text('summary_auto_interval_label'.tr()), findsNothing);
    // …and neither is the master switch, which was in the header.
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('the header button opens the settings, switch and all', (
    tester,
  ) async {
    final container = await _seed();
    await _openSheet(tester, container);

    await _openSettings(tester);

    expect(find.byType(SummarySettingsSheet), findsOneWidget);
    expect(find.text('label_enabled'.tr()), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('summary_auto_interval_label'.tr()), findsOneWidget);
    expect(find.text('summary_prompt_label'.tr()), findsOneWidget);
  });

  testWidgets('the switch in the settings is the injection master switch', (
    tester,
  ) async {
    final container = await _seed();
    await _openSheet(tester, container);
    expect(
      await container.read(summaryServiceProvider).isSummaryEnabled(_sessionId),
      isTrue,
    );

    await _openSettings(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check_rounded));
    await _settle(tester);

    // Buffered until Save, then written — and the sheet is gone.
    expect(find.byType(SummarySettingsSheet), findsNothing);
    await tester.runAsync(() async {
      expect(
        await container
            .read(summaryServiceProvider)
            .isSummaryEnabled(_sessionId),
        isFalse,
      );
      // The summary text itself is untouched by the switch.
      expect(
        await container
            .read(summaryServiceProvider)
            .getSummaryContent(_sessionId),
        'They reached the pass after dark.',
      );
    });
  });

  testWidgets('dismissing the settings writes nothing', (tester) async {
    final container = await _seed();
    await _openSheet(tester, container);

    await _openSettings(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    // Back, not Save.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await _settle(tester);

    await tester.runAsync(() async {
      expect(
        await container
            .read(summaryServiceProvider)
            .isSummaryEnabled(_sessionId),
        isTrue,
      );
    });
  });
}
