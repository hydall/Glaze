import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt_block_resolver.dart';
import 'package:glaze_flutter/core/models/character.dart';

/// Characterization test for the preset accounting split
/// (introduced to fix the double-count where preset chrome that
/// contained `{{memory}}` had its expanded memory tokens attributed
/// to BOTH `sourceTokens['preset']` AND `sourceTokens['memory']`).
///
/// The fix: `resolveBlockContent` now returns TWO flavours of the
/// resolved content:
/// * `content` — fully expanded (what the LLM actually sees)
/// * `contentForAccounting` — dynamic macro injections
///   (`{{summary}}`, `{{memory}}`, `{{lorebooks}}`, `{{guidance}}`)
///   blanked out, so the preset's "static chrome" tokens are
///   attributed to `sourceTokens['preset']` only, not double-counted
///   under `sourceTokens['memory']` etc.
void main() {
  Character makeChar() => Character(
    id: 'c1',
    name: 'Alice',
    description: 'A test character.',
    personality: 'Cheerful and helpful.',
    scenario: 'Meeting at a cafe.',
  );

  MacroContext makeCtx({
    String? summary,
    String? memory,
    String? lorebooks,
    String? guidance,
  }) =>
      MacroContext(
        charName: 'Alice',
        charId: 'c1',
        sessionId: 's1',
        charPersonality: 'Cheerful and helpful.',
        summaryContent: summary,
        memoryContent: memory,
        lorebooksContent: lorebooks,
        guidanceText: guidance,
      );

  group('content vs contentForAccounting', () {
    test('static block (no dynamic macros) is identical in both', () {
      final result = resolveBlockContent(
        id: 'custom',
        rawContent: 'You are a helpful assistant.',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(memory: 'memory content'),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
      );
      expect(result, isNotNull);
      expect(result!.content, result.contentForAccounting);
    });

    test('{{memory}} is expanded in content, blanked in contentForAccounting', () {
      final result = resolveBlockContent(
        id: 'custom',
        rawContent: 'Memory: {{memory}}',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(memory: 'this is the memory text'),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
      );
      expect(result, isNotNull);
      expect(result!.content, 'Memory: this is the memory text');
      expect(result.contentForAccounting, 'Memory: ',
          reason: '{{memory}} must be replaced with empty string in accounting');
    });

    test('{{summary}} as macro (in a custom block) is expanded in content, blanked in contentForAccounting', () {
      // When the user puts {{summary}} in a custom preset block (not the
      // special 'summary' id), the macro engine handles it via the
      // summaryContent field of MacroContext. That field is nulled out
      // for the accounting pass, so the macro is blanked.
      final result = resolveBlockContent(
        id: 'custom',
        rawContent: 'Summary: {{summary}}',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(summary: 'A long summary text'),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
      );
      expect(result, isNotNull);
      expect(result!.content, 'Summary: A long summary text');
      expect(result.contentForAccounting, 'Summary: ',
          reason: '{{summary}} must be blanked in contentForAccounting');
    });

    test('{{lorebooks}} is expanded in content, blanked in contentForAccounting', () {
      final result = resolveBlockContent(
        id: 'custom',
        rawContent: 'Lore: {{lorebooks}}',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(lorebooks: 'triggered lorebook content'),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
      );
      expect(result, isNotNull);
      expect(result!.content, 'Lore: triggered lorebook content');
      expect(result.contentForAccounting, 'Lore: ',
          reason: '{{lorebooks}} must be blanked in contentForAccounting');
    });

    test('{{guidance}} is expanded in content, blanked in contentForAccounting', () {
      final result = resolveBlockContent(
        id: 'guided_generation',
        rawContent: 'Guidance: {{guidance}}',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(guidance: 'be brief'),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
      );
      expect(result, isNotNull);
      expect(result!.content, 'Guidance: be brief');
      expect(result.contentForAccounting, 'Guidance: ',
          reason: '{{guidance}} must be blanked in contentForAccounting');
    });
  });

  group('static macros still expand in contentForAccounting', () {
    test('{{personality}} is expanded in content, blanked in contentForAccounting', () {
      final result = resolveBlockContent(
        id: 'custom',
        rawContent: 'P: {{personality}}',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
      );
      expect(result, isNotNull);
      expect(result!.content, contains('Cheerful'));
      expect(result.contentForAccounting, 'P: ');
    });

    test('{{char}} is expanded in content, blanked in contentForAccounting', () {
      final result = resolveBlockContent(
        id: 'custom',
        rawContent: 'Hello {{char}}!',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
      );
      expect(result, isNotNull);
      expect(result!.content, 'Hello Alice!');
      expect(result.contentForAccounting, 'Hello !',
          reason: '{{char}} is external; preset accounting keeps chrome only');
    });
  });

  group('{{setvar}} / {{getvar}} behaviour preserved', () {
    // Note: {{setvar}} as standalone content resolves to empty string
    // (the macro itself is removed), so resolveBlockContent returns
    // null and notifyObj is not touched. To exercise setvar inside
    // real content, see the integration tests in append_to_last_message_test.dart
    // and the macro engine unit tests.
    test('{{setvar}} inside longer content: notifyObj.varsChanged flips to true', () {
      final notify = NotifyObj();
      final result = resolveBlockContent(
        id: 'custom',
        rawContent: 'prefix {{setvar::x::42}} suffix',
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: notify,
      );
      expect(result, isNotNull);
      expect(notify.varsChanged, isTrue);
      expect(notify.sessionVars['x'], '42');
    });
  });
}
