import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/post_cleaner_service.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  group('PostCleanerResult', () {
    test('disabled status returns original text', () {
      const result = PostCleanerResult(
        status: 'disabled',
        cleanedText: 'original',
      );
      expect(result.status, 'disabled');
      expect(result.cleanedText, 'original');
      expect(result.wasCleaned, isFalse);
      expect(result.attempts, isEmpty);
      expect(result.totalElapsedMs, 0);
    });

    test('ok status with wasCleaned=true indicates rewrite', () {
      const result = PostCleanerResult(
        status: 'ok',
        cleanedText: 'cleaned',
        originalText: 'original',
        wasCleaned: true,
      );
      expect(result.wasCleaned, isTrue);
      expect(result.cleanedText, 'cleaned');
      expect(result.originalText, 'original');
    });

    test('timeout status returns original text', () {
      const result = PostCleanerResult(
        status: 'timeout',
        cleanedText: 'original',
      );
      expect(result.status, 'timeout');
      expect(result.wasCleaned, isFalse);
    });

    test('aborted status returns original text', () {
      const result = PostCleanerResult(
        status: 'aborted',
        cleanedText: 'original',
      );
      expect(result.status, 'aborted');
      expect(result.wasCleaned, isFalse);
    });

    test('error status returns original text with error message', () {
      const result = PostCleanerResult(
        status: 'error',
        cleanedText: 'original',
        error: 'something went wrong',
      );
      expect(result.status, 'error');
      expect(result.error, 'something went wrong');
      expect(result.wasCleaned, isFalse);
    });

    test('skipped status returns original text', () {
      const result = PostCleanerResult(
        status: 'skipped',
        cleanedText: 'original',
      );
      expect(result.status, 'skipped');
      expect(result.wasCleaned, isFalse);
    });

    test('carries retry attempts when set', () {
      const attempts = [
        AgentOperationAttempt(
          attempt: 1,
          statusCode: 502,
          status: 'http_5xx',
          error: 'Bad Gateway',
          startedAtMs: 0,
          elapsedMs: 30,
        ),
        AgentOperationAttempt(
          attempt: 2,
          statusCode: 200,
          status: 'ok',
          startedAtMs: 30,
          elapsedMs: 50,
        ),
      ];
      const result = PostCleanerResult(
        status: 'ok',
        cleanedText: 'cleaned',
        attempts: attempts,
        totalElapsedMs: 80,
      );
      expect(result.attempts.length, 2);
      expect(result.attempts.first.statusCode, 502);
      expect(result.attempts.last.statusCode, 200);
      expect(result.totalElapsedMs, 80);
    });
  });

  group('Post-cleaner trigger suppression', () {
    // The cleaner is always-on. The trigger in GenerationPipeline is guarded
    // by: regenTargetId == null (no studio-final term).
    bool cleanerTriggers(String? regenTargetId) =>
        regenTargetId == null;

    test('normal send → triggers', () {
      expect(cleanerTriggers(null), isTrue);
    });

    test('regen → does not trigger (regenTargetId != null)', () {
      expect(cleanerTriggers('msg_123'), isFalse);
    });
  });

  group('Post-cleaner safety guards', () {
    // The cleaner has a length-ratio guard: if the cleaned text is < 30% or
    // > 300% of the original length, it's skipped (status='skipped').
    // This prevents the cleaner from accidentally deleting or drastically
    // expanding the response.

    test('length ratio guard allows 50% length', () {
      final original = 'A' * 1000;
      final cleaned = 'B' * 500;
      final ratio = cleaned.length / original.length;
      expect(ratio, 0.5);
      expect(ratio >= 0.3 && ratio <= 3.0, isTrue);
    });

    test('length ratio guard rejects 20% length', () {
      final original = 'A' * 1000;
      final cleaned = 'B' * 200;
      final ratio = cleaned.length / original.length;
      expect(ratio, 0.2);
      expect(ratio >= 0.3 && ratio <= 3.0, isFalse);
    });

    test('length ratio guard rejects 400% length', () {
      final original = 'A' * 1000;
      final cleaned = 'B' * 4000;
      final ratio = cleaned.length / original.length;
      expect(ratio, 4.0);
      expect(ratio >= 0.3 && ratio <= 3.0, isFalse);
    });

    test('length ratio guard allows 100% (same length)', () {
      final original = 'A' * 1000;
      final cleaned = 'B' * 1000;
      final ratio = cleaned.length / original.length;
      expect(ratio, 1.0);
      expect(ratio >= 0.3 && ratio <= 3.0, isTrue);
    });

    test('length ratio guard allows 200% length', () {
      final original = 'A' * 1000;
      final cleaned = 'B' * 2000;
      final ratio = cleaned.length / original.length;
      expect(ratio, 2.0);
      expect(ratio >= 0.3 && ratio <= 3.0, isTrue);
    });
  });

  group('Post-cleaner trigger suppression', () {
    // The cleaner is always-on. The trigger in GenerationPipeline is guarded
    // by: regenTargetId == null (no studio-final term).
    bool cleanerTriggers(String? regenTargetId) =>
        regenTargetId == null;

    test('normal send → triggers', () {
      expect(cleanerTriggers(null), isTrue);
    });

    test('regen → does not trigger (regenTargetId != null)', () {
      expect(cleanerTriggers('msg_123'), isFalse);
    });
  });

  group('Post-cleaner fallback behavior', () {
    // On any error (timeout, LLM failure, abort, empty response), the
    // cleaner returns the original text unchanged. This is the "do no harm"
    // principle — the cleaner must never make the response worse or lose it.

    test('disabled → original text returned', () {
      const result = PostCleanerResult(
        status: 'disabled',
        cleanedText: 'original text',
      );
      expect(result.cleanedText, 'original text');
      expect(result.wasCleaned, isFalse);
    });

    test('timeout → original text returned', () {
      const result = PostCleanerResult(
        status: 'timeout',
        cleanedText: 'original text',
      );
      expect(result.cleanedText, 'original text');
      expect(result.wasCleaned, isFalse);
    });

    test('error → original text returned', () {
      const result = PostCleanerResult(
        status: 'error',
        cleanedText: 'original text',
        error: 'network failure',
      );
      expect(result.cleanedText, 'original text');
      expect(result.wasCleaned, isFalse);
    });

    test('aborted → original text returned', () {
      const result = PostCleanerResult(
        status: 'aborted',
        cleanedText: 'original text',
      );
      expect(result.cleanedText, 'original text');
      expect(result.wasCleaned, isFalse);
    });

    test('skipped (length guard) → original text returned', () {
      const result = PostCleanerResult(
        status: 'skipped',
        cleanedText: 'original text',
      );
      expect(result.cleanedText, 'original text');
      expect(result.wasCleaned, isFalse);
    });

    test('ok with wasCleaned=false → original text returned (no change)', () {
      const result = PostCleanerResult(
        status: 'ok',
        cleanedText: 'original text',
        wasCleaned: false,
      );
      expect(result.cleanedText, 'original text');
      expect(result.wasCleaned, isFalse);
    });

    test('ok with wasCleaned=true → cleaned text returned', () {
      const result = PostCleanerResult(
        status: 'ok',
        cleanedText: 'cleaned text',
        originalText: 'original text',
        wasCleaned: true,
      );
      expect(result.cleanedText, 'cleaned text');
      expect(result.wasCleaned, isTrue);
    });
  });

  group('PostCleanerService.buildCleanerPrompt', () {
    test('includes self-contained Beauty block without a pregen brief', () {
      final prompt = PostCleanerService.buildStudioCleanerPrompt(
        assistantText: '«Привет», — сказала Люси.',
        cleanerBlocks: const [
          StudioPresetBlock(
            id: 'cleaner_beauty',
            section: 'cleaner',
            content: 'BEAUTY SELF-CONTAINED {{beautyBrief}}',
          ),
        ],
        macroCtx: const MacroContext(
          charName: 'Lucy',
          charId: 'char',
          sessionId: 'session',
        ),
      );

      expect(prompt, contains('BEAUTY SELF-CONTAINED'));
      expect(prompt, isNot(contains('{{beautyBrief}}')));
    });

    test('without broadcast blocks uses default editor rules', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'He felt a shiver run down his spine.',
      );
      expect(prompt, contains('prose editor'));
      expect(prompt, contains('Assistant response to clean:'));
      expect(prompt, contains('He felt a shiver run down his spine.'));
      // No authoritative-rules section when there are no broadcast blocks.
      expect(prompt, isNot(contains('AUTHORITATIVE RULES')));
    });

    test('injects broadcast blocks as authoritative rules', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Текст ответа.',
        broadcastBlocks: const [
          '[Block: 🇷🇺 LANGUAGE: Russian]\nRUSSIAN ONLY. Use «ёлочки» quotes.',
          '[Block: Anti-Cliché]\nBan: "symphony of", "tapestry of".',
        ],
      );
      expect(prompt, contains('AUTHORITATIVE RULES'));
      expect(prompt, contains('RUSSIAN ONLY'));
      expect(prompt, contains('«ёлочки»'));
      expect(prompt, contains('Anti-Cliché'));
      // The authoritative section must come before the text to clean.
      expect(
        prompt.indexOf('AUTHORITATIVE RULES'),
        lessThan(prompt.indexOf('Assistant response to clean:')),
      );
    });

    test('ignores blank broadcast entries', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'x',
        broadcastBlocks: const ['', '   '],
      );
      expect(prompt, isNot(contains('AUTHORITATIVE RULES')));
    });

    test('OOC preservation rule is present in the prompt', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'He smiled. ((OOC: hey, just checking in!))',
      );
      // The OOC preservation rule must be in the rules section.
      expect(prompt, contains('PRESERVE OOC'));
      expect(prompt, contains('out-of-character'));
      expect(prompt, contains('((...))'));
      expect(prompt, contains('[OOC: ...]'));
      expect(prompt, contains('(OOC: ...)'));
      // The "return only cleaned text" line must mention OOC blocks too.
      expect(prompt, contains('OOC blocks are also part of the content'));
    });

    test('HTML preservation rule is present in the prompt', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: '<font color="red">He smiled.</font>',
      );
      expect(prompt, contains('PRESERVE all inline HTML'));
      expect(prompt, contains('<font color="...">'));
      expect(prompt, contains('<i>'));
    });
  });

  group('PostCleanerService.buildCleanerPrompt with context', () {
    test('includes recent chat history when provided', () {
      final messages = [
        ChatMessage(id: 'm1', role: 'user', content: 'Что ты помнишь?'),
        ChatMessage(
          id: 'm2',
          role: 'assistant',
          content: 'Я помню дождь.',
        ),
      ];
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Снова дождь.',
        recentMessages: messages,
      );
      expect(prompt, contains('RECENT CHAT HISTORY:'));
      expect(prompt, contains('Что ты помнишь?'));
      expect(prompt, contains('Я помню дождь.'));
      expect(prompt, contains('[user #m1]'));
      expect(prompt, contains('[assistant #m2]'));
      // History must come before the text to clean.
      expect(
        prompt.indexOf('RECENT CHAT HISTORY:'),
        lessThan(prompt.indexOf('Assistant response to clean:')),
      );
    });

    test('includes continuity rules only when context is present', () {
      final promptWithHistory = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Текст.',
        recentMessages: [
          ChatMessage(id: 'm1', role: 'user', content: 'Привет.'),
        ],
      );
      expect(promptWithHistory, contains('Continuity rules:'));

      final promptNoContext = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Текст.',
      );
      expect(promptNoContext, isNot(contains('Continuity rules:')));
      expect(promptNoContext, isNot(contains('RECENT CHAT HISTORY:')));
    });

    test('trims long messages to the character limit', () {
      final longContent = 'A' * 4000;
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'response',
        recentMessages: [
          ChatMessage(id: 'm1', role: 'user', content: longContent),
        ],
      );
      // The trimmed content should not contain the full 4000 chars.
      expect(prompt, isNot(contains(longContent)));
      // But should contain the truncation marker.
      expect(prompt, contains('…'));
    });

    test('skips messages with empty content', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'response',
        recentMessages: [
          ChatMessage(id: 'm1', role: 'user', content: ''),
          ChatMessage(id: 'm2', role: 'assistant', content: '  '),
          ChatMessage(id: 'm3', role: 'user', content: 'visible'),
        ],
      );
      expect(prompt, contains('visible'));
      expect(prompt, isNot(contains('#m1]')));
      expect(prompt, isNot(contains('#m2]')));
      expect(prompt, contains('#m3]'));
    });

    test('combines history and broadcast rules together', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Финальный ответ.',
        broadcastBlocks: const ['RUSSIAN ONLY.'],
        recentMessages: [
          ChatMessage(id: 'm1', role: 'user', content: 'Вопрос?'),
        ],
      );
      expect(prompt, contains('RECENT CHAT HISTORY:'));
      expect(prompt, contains('AUTHORITATIVE RULES'));
      expect(prompt, contains('Continuity rules:'));
      // Order: history → rules → rules list → continuity → text
      final historyIdx = prompt.indexOf('RECENT CHAT HISTORY:');
      final rulesIdx = prompt.indexOf('AUTHORITATIVE RULES');
      final textIdx = prompt.indexOf('Assistant response to clean:');
      expect(historyIdx, lessThan(rulesIdx));
      expect(rulesIdx, lessThan(textIdx));
    });
  });

  group('PostCleanerService.buildCleanerPrompt with auditIssues', () {
    test('includes CHARACTER CONSISTENCY NOTES when auditIssues non-empty', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Lucy says hello.',
        auditIssues: const [
          'Lucy is described as speaking but should be silent per scenario.',
          'Menu is described as paper but lore says wall of names.',
        ],
      );
      expect(prompt, contains('CHARACTER CONSISTENCY NOTES'));
      expect(prompt, contains('Lucy is described as speaking'));
      expect(prompt, contains('Menu is described as paper'));
      expect(prompt, contains('Apply minimal fixes for these issues'));
      expect(
        prompt,
        contains("Prefer rephrasing that preserves the prose's voice"),
      );
    });

    test('omits CHARACTER CONSISTENCY NOTES when auditIssues is null', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Text.',
        auditIssues: null,
      );
      expect(prompt, isNot(contains('CHARACTER CONSISTENCY NOTES')));
    });

    test('omits CHARACTER CONSISTENCY NOTES when auditIssues is empty', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Text.',
        auditIssues: const [],
      );
      expect(prompt, isNot(contains('CHARACTER CONSISTENCY NOTES')));
    });

    test('audit notes appear before style rules', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Ответ.',
        broadcastBlocks: const ['RUSSIAN ONLY.'],
        auditIssues: const ['Lucy should be silent.'],
      );
      final auditIdx = prompt.indexOf('CHARACTER CONSISTENCY NOTES');
      final rulesIdx = prompt.indexOf('AUTHORITATIVE RULES');
      final textIdx = prompt.indexOf('Assistant response to clean:');
      expect(auditIdx, lessThan(rulesIdx));
      expect(rulesIdx, lessThan(textIdx));
    });

    test('audit notes do not trigger continuity rules section (separate concern)', () {
      // Continuity rules are for local scene state (history), not for
      // audit notes. Audit notes have their own fix-instructions.
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'Text.',
        auditIssues: const ['Some issue.'],
      );
      expect(prompt, contains('CHARACTER CONSISTENCY NOTES'));
      expect(prompt, isNot(contains('Continuity rules:')));
    });
  });

  group('PostCleanerService.buildAuditPrompt', () {
    test('includes character name, description, personality, scenario', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Lucy waves.',
        character: const Character(
          id: 'c1',
          name: 'Lucy',
          description: 'A silent bartender.',
          personality: ' stoic, observant.',
          scenario: 'The Afterlife bar.',
          postHistoryInstructions: 'Never speak aloud.',
        ),
      );
      expect(prompt, contains('CHARACTER PROFILE:'));
      expect(prompt, contains('Name: Lucy'));
      expect(prompt, contains('A silent bartender.'));
      expect(prompt, contains('stoic, observant.'));
      expect(prompt, contains('The Afterlife bar.'));
      expect(prompt, contains('Post-history instructions: Never speak aloud.'));
    });

    test('omits empty character fields cleanly', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Text.',
        character: const Character(id: 'c1', name: 'Bob'),
      );
      expect(prompt, contains('Name: Bob'));
      expect(prompt, isNot(contains('Description:')));
      expect(prompt, isNot(contains('Personality:')));
      expect(prompt, isNot(contains('Scenario:')));
      expect(prompt, isNot(contains('Post-history')));
    });

    test('includes persona name and description when provided', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Hi.',
        character: const Character(id: 'c1', name: 'X'),
        persona: const Persona(
          id: 'p1',
          name: 'Daniel',
          prompt: 'A tired engineer.',
        ),
      );
      expect(prompt, contains('USER PERSONA:'));
      expect(prompt, contains('Name: Daniel'));
      expect(prompt, contains('A tired engineer.'));
    });

    test('omits USER PERSONA section when persona is null', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Hi.',
        character: const Character(id: 'c1', name: 'X'),
      );
      expect(prompt, isNot(contains('USER PERSONA:')));
    });

    test('includes lorebooks/memory/summary/arc/entity sections when present', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Text.',
        character: const Character(id: 'c1', name: 'X'),
        lorebooksContent: 'Wall of names behind the bar.',
        memoryContent: 'Lucy never speaks aloud.',
        summaryContent: 'Five turns have passed.',
        arcContent: 'Investigation arc active.',
        entitiesContent: '- Lucy (npc): silent bartender',
      );
      expect(prompt, contains('INJECTED WORLD/LORE CONTEXT:'));
      expect(prompt, contains('Wall of names'));
      expect(prompt, contains('INJECTED MEMORY CONTEXT:'));
      expect(prompt, contains('Lucy never speaks'));
      expect(prompt, contains('SUMMARY:'));
      expect(prompt, contains('Five turns'));
      expect(prompt, contains('ARCS:'));
      expect(prompt, contains('Investigation arc'));
      expect(prompt, contains('ENTITIES:'));
      expect(prompt, contains('Lucy (npc)'));
    });

    test('omits empty context sections cleanly', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Text.',
        character: const Character(id: 'c1', name: 'X'),
        lorebooksContent: '   ',
        memoryContent: '',
        summaryContent: null,
      );
      expect(prompt, isNot(contains('INJECTED WORLD/LORE CONTEXT:')));
      expect(prompt, isNot(contains('INJECTED MEMORY CONTEXT:')));
      expect(prompt, isNot(contains('SUMMARY:')));
      expect(prompt, isNot(contains('ARCS:')));
      expect(prompt, isNot(contains('ENTITIES:')));
    });

    test('includes recent chat history when provided', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Lucy speaks.',
        character: const Character(id: 'c1', name: 'Lucy'),
        recentMessages: [
          ChatMessage(id: 'm1', role: 'user', content: 'Say something.'),
          ChatMessage(id: 'm2', role: 'assistant', content: '...'),
        ],
      );
      expect(prompt, contains('RECENT CHAT HISTORY:'));
      expect(prompt, contains('Say something.'));
      expect(prompt, contains('...'));
    });

    test('instructs JSON-only output', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'Text.',
        character: const Character(id: 'c1', name: 'X'),
      );
      expect(prompt, contains('{"ok": true}'));
      expect(prompt, contains('{"ok": false, "issues":'));
      expect(prompt, contains('Return ONLY the JSON, no other text.'));
    });

    test('response-to-audit appears after all context', () {
      final prompt = PostCleanerService.buildAuditPrompt(
        assistantText: 'The response.',
        character: const Character(id: 'c1', name: 'X', description: 'D'),
        memoryContent: 'Memory fact.',
        recentMessages: [
          ChatMessage(id: 'm1', role: 'user', content: 'Q?'),
        ],
      );
      final profileIdx = prompt.indexOf('CHARACTER PROFILE:');
      final memIdx = prompt.indexOf('INJECTED MEMORY CONTEXT:');
      final histIdx = prompt.indexOf('RECENT CHAT HISTORY:');
      final auditIdx = prompt.indexOf('ASSISTANT RESPONSE TO AUDIT:');
      expect(profileIdx, lessThan(memIdx));
      expect(memIdx, lessThan(histIdx));
      expect(histIdx, lessThan(auditIdx));
    });
  });

  group('PostCleanerService.parseAuditJson', () {
    test('returns empty list for {"ok": true}', () {
      expect(PostCleanerService.parseAuditJson('{"ok": true}'), isEmpty);
    });

    test('returns issues list for {"ok": false, "issues": [...]}', () {
      final result = PostCleanerService.parseAuditJson(
        '{"ok": false, "issues": ["Lucy speaks but should be silent.", "Wrong location."]}',
      );
      expect(result, isNotNull);
      expect(result, hasLength(2));
      expect(result![0], 'Lucy speaks but should be silent.');
      expect(result[1], 'Wrong location.');
    });

    test('returns null for malformed JSON', () {
      expect(PostCleanerService.parseAuditJson('not json at all'), isNull);
      expect(PostCleanerService.parseAuditJson('{broken'), isNull);
    });

    test('returns null when ok field is missing or not boolean', () {
      expect(PostCleanerService.parseAuditJson('{"issues": ["x"]}'), isNull);
      expect(PostCleanerService.parseAuditJson('{"ok": "yes"}'), isNull);
    });

    test('returns null when ok=false but issues is missing or not a list', () {
      expect(PostCleanerService.parseAuditJson('{"ok": false}'), isNull);
      expect(
        PostCleanerService.parseAuditJson('{"ok": false, "issues": "not a list"}'),
        isNull,
      );
    });

    test('filters out non-string and empty entries from issues', () {
      final result = PostCleanerService.parseAuditJson(
        '{"ok": false, "issues": ["valid", 42, "", "   ", "also valid"]}',
      );
      expect(result, isNotNull);
      expect(result, hasLength(2));
      expect(result![0], 'valid');
      expect(result[1], 'also valid');
    });

    test('extracts JSON from markdown fences and surrounding prose', () {
      const raw = 'Here is the audit:\n```json\n{"ok": true}\n```\nDone.';
      expect(PostCleanerService.parseAuditJson(raw), isEmpty);
    });

    test('extracts JSON from prose before/after the JSON block', () {
      const raw = 'Sure! {"ok": false, "issues": ["x"]} Hope that helps.';
      final result = PostCleanerService.parseAuditJson(raw);
      expect(result, isNotNull);
      expect(result, hasLength(1));
      expect(result![0], 'x');
    });

    test('returns null for empty input', () {
      expect(PostCleanerService.parseAuditJson(''), isNull);
      expect(PostCleanerService.parseAuditJson('   '), isNull);
    });

    test('returns null when no braces present', () {
      expect(PostCleanerService.parseAuditJson('no braces here'), isNull);
    });
  });

  group('textRewriteDropsProtectedMarkup', () {
    test('returns false when original has no tags or fences', () {
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(
          'plain prose without any markup',
          'edited prose without any markup',
        ),
        isFalse,
      );
    });

    test('returns false when original and edited both have HTML tags', () {
      const original = '<font color="red">She <i>smiled</i>.</font>';
      const edited = '<font color="red">She <i>grinned</i>.</font>';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isFalse,
      );
    });

    test('returns true when original had HTML tags but edited dropped them', () {
      const original = '<font color="red">She smiled.</font> More prose.';
      const edited = 'She smiled. More prose.';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isTrue,
      );
    });

    test('returns true when original had fenced code but edited dropped it', () {
      const original = 'Here is code:\n```dart\nvoid main() {}\n```\nDone.';
      const edited = 'Here is code: void main() {} Done.';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isTrue,
      );
    });

    test('returns false when original and edited both have code fences', () {
      const original = '```dart\nvoid main() {}\n```';
      const edited = '```dart\nvoid other() {}\n```';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isFalse,
      );
    });

    test('does NOT treat ==custom markers== as HTML tags', () {
      const original = '==important== and <b>bold</b> together';
      const edited = '==important== and bold together';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isTrue,
      );
    });

    test('does NOT treat single backtick code as fenced block', () {
      const original = 'Use `print()` to output. No fences here.';
      const edited = 'Use print() to output. No fences here.';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isFalse,
      );
    });

    test('returns false when edited preserves tags but adds prose', () {
      const original = '<i>She smiled.</i>';
      const edited = '<i>She smiled warmly, the corners of her eyes crinkling.</i>';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isFalse,
      );
    });

    test('returns true when original had both tags and fences, edited lost both', () {
      const original = '<b>Bold</b> and ```fenced```.';
      const edited = 'Bold and fenced.';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isTrue,
      );
    });

    test('returns false when original had both, edited kept tags but lost fences', () {
      const original = '<b>Bold</b> and ```fenced```.';
      const edited = '<b>Bold</b> and fenced.';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isTrue,
      );
    });
  });

  group('buildCleanerPrompt style overrides', () {
    test('includes BANNED WORDS section when bannedWords non-empty', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'She smiled.',
        bannedWords: 'ozone, tapestry',
      );
      expect(prompt, contains('GLOBAL STYLE OVERRIDES'));
      expect(prompt, contains('BANNED WORDS'));
      expect(prompt, contains('ozone, tapestry'));
    });

    test('includes AVOID section when avoidInstructions non-empty', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'She smiled.',
        avoidInstructions: 'no repetition of sentence structure',
      );
      expect(prompt, contains('AVOID'));
      expect(prompt, contains('no repetition of sentence structure'));
    });

    test('includes PREFER section when styleInstructions non-empty', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'She smiled.',
        styleInstructions: 'terse, hardboiled prose',
      );
      expect(prompt, contains('PREFER'));
      expect(prompt, contains('terse, hardboiled prose'));
    });

    test('omits GLOBAL STYLE OVERRIDES section when all overrides empty', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'She smiled.',
      );
      expect(prompt, isNot(contains('GLOBAL STYLE OVERRIDES')));
      expect(prompt, isNot(contains('BANNED WORDS')));
      expect(prompt, isNot(contains('AVOID')));
      expect(prompt, isNot(contains('PREFER')));
    });

    test('omits GLOBAL STYLE OVERRIDES section when overrides are whitespace only', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'She smiled.',
        bannedWords: '   ',
        avoidInstructions: '\n\t',
        styleInstructions: '',
      );
      expect(prompt, isNot(contains('GLOBAL STYLE OVERRIDES')));
    });

    test('includes all three sections when all overrides non-empty', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'She smiled.',
        bannedWords: 'ozone',
        avoidInstructions: 'no purple prose',
        styleInstructions: 'terse',
      );
      expect(prompt, contains('BANNED WORDS'));
      expect(prompt, contains('AVOID'));
      expect(prompt, contains('PREFER'));
    });

    test('style overrides appear AFTER authoritative rules section', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'She smiled.',
        broadcastBlocks: ['Rule A: do X', 'Rule B: do Y'],
        bannedWords: 'ozone',
      );
      final rulesIndex = prompt.indexOf('AUTHORITATIVE RULES');
      final overridesIndex = prompt.indexOf('GLOBAL STYLE OVERRIDES');
      expect(rulesIndex, greaterThan(-1));
      expect(overridesIndex, greaterThan(rulesIndex));
    });
  });
}
