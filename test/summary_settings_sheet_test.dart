import 'dart:convert';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';
import 'package:glaze_flutter/core/services/summary_preamble.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/state/summary_regeneration_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/summary_settings_sheet.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

/// The Summary tab used to be the text plus every setting the summary has, with
/// the master switch promoted into the sheet header as a bare `Switch`. It is
/// the block chain and its actions now; the settings live behind the header's
/// button, as the Memory Books tab's do.
const _charId = 'char-summary';
const _sessionId = 'session-summary';

const _hello = ChatMessage(
  id: 'm1',
  role: 'user',
  content: 'Hello',
  timestamp: 1,
);

const _note = SummaryBlock(
  id: 'note',
  level: 0,
  content: 'They reached the pass after dark.',
);

Future<ProviderContainer> _seed({
  List<SummaryBlock> blocks = const [_note],
  bool regenerating = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  ChatSessionService.clearCache();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      if (regenerating)
        summaryRegenerationProvider.overrideWith(_RegeneratingB1.new),
    ],
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
          messages: [_hello],
        ),
      );
  await container
      .read(summaryServiceProvider)
      .saveBlocks(
        sessionId: _sessionId,
        blocks: blocks,
        messages: const [_hello],
      );
  await container.read(chatProvider(_charId).future);
  return container;
}

/// A run writing `b1` again, started three seconds ago.
class _RegeneratingB1 extends SummaryRegenerationNotifier {
  @override
  SummaryRegenerationState build() => SummaryRegenerationState(
    startedAt: {
      SummaryRegenerationState.key(_sessionId, 'b1'): DateTime.now().subtract(
        const Duration(seconds: 3),
      ),
    },
  );
}

final _helloHash = SummaryChain.fingerprint(const [
  'm1',
], SummaryChain.index(const [_hello]));

SummaryBlock _retold({SummaryDraft? draft}) => SummaryBlock(
  id: 'b1',
  level: 1,
  content: 'Alice was greeted.',
  messageIds: const ['m1'],
  sourceHash: _helloHash,
  draft: draft,
);

final _draft = SummaryDraft(
  content: 'Alice was greeted warmly at the gate.',
  messageIds: const ['m1'],
  sourceHash: _helloHash,
  tokens: 9,
  sourceTokens: 40,
);

Future<SummaryBlock> _storedB1(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final blocks = await tester.runAsync(
    () => container.read(summaryServiceProvider).getBlocks(_sessionId),
  );
  return blocks!.firstWhere((b) => b.id == 'b1');
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

/// The prompts sit below the compaction controls, past what the list builds
/// up front.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: find.byType(SummarySettingsSheet),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pump();
}

/// What Save wrote, read from the prefs rather than the provider: with the
/// sheet closed nothing listens to it any more.
Future<SummaryPromptSelection> _savedSelection() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(SummaryPromptSelectionNotifier.prefsKey);
  return SummaryPromptSelection.fromJson(
    jsonDecode(raw ?? '{}') as Map<String, dynamic>,
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('the tab is the block chain and its actions', (tester) async {
    final container = await _seed();
    await _openSheet(tester, container);

    expect(find.text('They reached the pass after dark.'), findsOneWidget);
    expect(find.text('summary_note'.tr()), findsWidgets);
    // The kit's buttons, not Material ones in a hand-picked blue.
    expect(find.text('summary_compact_now'.tr()), findsOneWidget);
    expect(find.text('summary_clear'.tr()), findsOneWidget);
    expect(find.byType(GlazeActionButton), findsNWidgets(3));
    expect(find.byType(FilledButton), findsNothing);
    // The settings are not in the tab any more…
    expect(find.text('summary_prompts_section'.tr()), findsNothing);
    expect(find.text('summary_trigger_label'.tr()), findsNothing);
    // …and neither is the master switch, which was in the header.
    expect(find.byType(Switch), findsNothing);
    // A note is the reader's own text: nothing to regenerate.
    expect(find.text('memory_books_btn_regenerate'.tr()), findsNothing);
  });

  testWidgets('a retold block can be regenerated, as a Memory Books draft', (
    tester,
  ) async {
    final container = await _seed(blocks: [_note, _retold()]);
    await _openSheet(tester, container);

    expect(find.text('Alice was greeted.'), findsOneWidget);
    expect(find.text('memory_books_btn_regenerate'.tr()), findsOneWidget);
    // Nothing waits for approval yet.
    expect(find.byTooltip('memory_books_btn_approve'.tr()), findsNothing);
  });

  testWidgets('a running regeneration counts the seconds and can be stopped', (
    tester,
  ) async {
    final container = await _seed(
      blocks: [_note, _retold()],
      regenerating: true,
    );
    await _openSheet(tester, container);

    expect(find.text('memory_books_badge_generating'.tr()), findsOneWidget);
    expect(find.textContaining('3.'), findsOneWidget);
    expect(find.text('memory_books_btn_regenerate'.tr()), findsNothing);
    // The summarizer is taken: compaction waits for the run.
    final compact = tester.widget<GlazeActionButton>(
      find.widgetWithText(GlazeActionButton, 'summary_compact_now'.tr()),
    );
    expect(compact.onTap, isNull);

    await tester.tap(find.byTooltip('memory_books_btn_stop'.tr()));
    await tester.pump();

    expect(find.text('memory_books_badge_generating'.tr()), findsNothing);
    expect(find.text('memory_books_btn_regenerate'.tr()), findsOneWidget);
  });

  testWidgets('a draft waits on its card, and Approve puts it in the block', (
    tester,
  ) async {
    final container = await _seed(
      blocks: [
        _note,
        _retold(draft: _draft),
      ],
    );
    await _openSheet(tester, container);

    expect(find.text('Alice was greeted warmly at the gate.'), findsOneWidget);
    expect(find.text('Alice was greeted.'), findsNothing);
    expect(find.text('memory_books_badge_draft'.tr()), findsOneWidget);
    expect(
      find.textContaining('memory_books_pending_approval'.tr()),
      findsOneWidget,
    );
    expect(find.byTooltip('summary_draft_discard'.tr()), findsOneWidget);
    // Regenerate stays under the draft, as under a memory draft.
    expect(find.text('memory_books_btn_regenerate'.tr()), findsOneWidget);

    await tester.tap(find.byTooltip('memory_books_btn_approve'.tr()));
    await _settle(tester);

    final stored = await _storedB1(tester, container);
    expect(stored.content, 'Alice was greeted warmly at the gate.');
    expect(stored.draft, isNull);
    expect(find.text('memory_books_badge_draft'.tr()), findsNothing);
    expect(find.byTooltip('memory_books_btn_approve'.tr()), findsNothing);
    // Approving says so, as Save does.
    expect(find.text('summary_saved'.tr()), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('tapping a draft edits it in the Memory Books editor', (
    tester,
  ) async {
    final container = await _seed(
      blocks: [
        _note,
        _retold(draft: _draft),
      ],
    );
    await _openSheet(tester, container);

    await tester.tap(find.text('Alice was greeted warmly at the gate.'));
    await _settle(tester);
    // Named by the messages it covers, as a memory entry is.
    expect(find.text('1'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Alice was greeted warmly at the gate.'),
      'Alice was let in.',
    );
    await tester.tap(find.text('btn_save'.tr()));
    await _settle(tester);

    final stored = await _storedB1(tester, container);
    expect(stored.draft?.content, 'Alice was let in.');
    expect(stored.content, 'Alice was greeted.');
    expect(find.text('Alice was let in.'), findsOneWidget);
    expect(find.text('summary_draft_saved'.tr()), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the header button opens the settings, switch and all', (
    tester,
  ) async {
    final container = await _seed();
    await _openSheet(tester, container);

    await _openSettings(tester);

    expect(find.byType(SummarySettingsSheet), findsOneWidget);
    expect(find.text('label_enabled'.tr()), findsOneWidget);
    // The master switch and the auto-compaction switch.
    expect(find.byType(Switch), findsNWidgets(2));
    expect(find.text('summary_auto_label'.tr()), findsOneWidget);
    expect(find.text('summary_trigger_label'.tr()), findsOneWidget);
    expect(find.text('summary_manual_tail_label'.tr()), findsOneWidget);
    // The manual tail is a share of the context by default; the token slider
    // shows only once tokens are picked.
    expect(find.text('summary_manual_tail_unit_percent'.tr()), findsOneWidget);
    expect(find.text('summary_manual_tail_percent_label'.tr()), findsOneWidget);
    expect(find.text('summary_manual_tail_tokens_label'.tr()), findsNothing);
    expect(find.text('summary_block_target_label'.tr()), findsOneWidget);
    expect(find.text('summary_merge_label'.tr()), findsOneWidget);
    // Summarizing runs on the Memory slot, so the settings say where that
    // slot is bound rather than leaving the reader to find it.
    expect(
      find.text('memory_books_generation_connection'.tr()),
      findsOneWidget,
    );
    expect(find.text('summary_connection_hint'.tr()), findsOneWidget);
    await _scrollTo(tester, find.byKey(const Key('summary_manage_prompts')));
    // Prompts are picked from presets, as in Memory Books: one for retelling,
    // one for merging, one for shortening, a view of them and the saved-prompt
    // manager. No text field to edit in place.
    expect(find.text('summary_prompt_retell_label'.tr()), findsOneWidget);
    expect(find.text('summary_prompt_merge_label'.tr()), findsOneWidget);
    expect(find.text('summary_prompt_shorten_label'.tr()), findsOneWidget);
    expect(find.text('summary_prompt_view_current'.tr()), findsOneWidget);
    expect(find.text('memory_prompt_manage'.tr()), findsOneWidget);
    // The refusal instruction's field shows only once its switch is on.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Recap (recommended)'), findsOneWidget);
    expect(find.text('Keep continuity (recommended)'), findsOneWidget);
    expect(find.text('Keep facts (recommended)'), findsOneWidget);
  });

  testWidgets('the refusal instruction is a switch over its text', (
    tester,
  ) async {
    final container = await _seed();
    await _openSheet(tester, container);
    await _openSettings(tester);

    await _scrollTo(tester, find.byKey(const Key('summary_preamble')));
    expect(find.text('summary_preamble_label'.tr()), findsOneWidget);
    expect(find.text('summary_preamble_hint'.tr()), findsOneWidget);
    // Off by default, and the text stays out of the way until it is on.
    expect(find.byKey(const Key('summary_preamble_text')), findsNothing);

    await tester.tap(find.byKey(const Key('summary_preamble')));
    await tester.pump();
    await _scrollTo(tester, find.byKey(const Key('summary_preamble_text')));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('summary_preamble_text')))
          .controller
          ?.text,
      SummaryPreamble.defaultText,
    );
    await tester.enterText(
      find.byKey(const Key('summary_preamble_text')),
      'Retell it all.',
    );
    await tester.tap(find.byIcon(Icons.check_rounded));
    await _settle(tester);

    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SummaryPreambleNotifier.prefsKey);
      expect(
        SummaryPreamble.fromJson(jsonDecode(raw!) as Map<String, dynamic>),
        const SummaryPreamble(enabled: true, text: 'Retell it all.'),
      );
    });
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
    await tester.tap(find.byType(Switch).first);
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
      // The summary itself is untouched by the switch.
      expect(
        (await container
                .read(summaryServiceProvider)
                .getBlocks(_sessionId))
            .single
            .content,
        'They reached the pass after dark.',
      );
    });
  });

  testWidgets('dismissing the settings writes nothing', (tester) async {
    final container = await _seed();
    await _openSheet(tester, container);

    await _openSettings(tester);
    await tester.tap(find.byType(Switch).first);
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

  testWidgets('picking a merge preset is saved as the selection', (
    tester,
  ) async {
    final container = await _seed();
    await _openSheet(tester, container);
    await _openSettings(tester);

    await _scrollTo(tester, find.byKey(const Key('summary_prompt_merge')));
    await tester.tap(find.byKey(const Key('summary_prompt_merge')));
    await _settle(tester);
    await tester.tap(find.text('Tight'));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.check_rounded));
    await _settle(tester);

    await tester.runAsync(() async {
      expect((await _savedSelection()).mergeKey, 'tight');
    });
  });

  testWidgets("a chat's own prompt is shown, and a preset replaces it", (
    tester,
  ) async {
    final container = await _seed();
    await tester.runAsync(
      () => container
          .read(summaryServiceProvider)
          .setSummaryPrompt(sessionId: _sessionId, prompt: 'Only this chat.'),
    );
    await _openSheet(tester, container);
    await _openSettings(tester);

    await _scrollTo(tester, find.byKey(const Key('summary_prompt_retell')));
    expect(find.text('summary_prompt_chat_own'.tr()), findsOneWidget);

    await tester.tap(find.byKey(const Key('summary_prompt_retell')));
    await _settle(tester);
    await tester.tap(find.text('State of play'));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.check_rounded));
    await _settle(tester);

    await tester.runAsync(() async {
      expect(
        await container
            .read(summaryServiceProvider)
            .getSummaryPrompt(_sessionId),
        isNull,
      );
      expect((await _savedSelection()).retellKey, 'state_of_play');
    });
  });
}
