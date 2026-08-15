import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt_block_resolver.dart';
import 'package:glaze_flutter/core/models/character.dart';

/// Empty expanded blocks are dropped unless the preset block explicitly opts
/// in to emitting an empty API message.
void main() {
  Character makeChar() => Character(
    id: 'c1',
    name: 'Alice',
    description: 'A test character.',
    personality: 'Cheerful and helpful.',
    scenario: 'Meeting at a cafe.',
  );

  MacroContext makeCtx() =>
      const MacroContext(charName: 'Alice', charId: 'c1', sessionId: 's1');

  ResolvedContent? resolve(String rawContent, {bool sendEmptyBlock = false}) =>
      resolveBlockContent(
        id: 'custom',
        rawContent: rawContent,
        role: 'system',
        char: makeChar(),
        persona: null,
        macroCtx: makeCtx(),
        sessionVars: const {},
        globalVars: const {},
        summaryContent: null,
        summaryPrefix: null,
        notifyObj: NotifyObj(),
        sendEmptyBlock: sendEmptyBlock,
      );

  group('block emptiness', () {
    test('a zero-length block is dropped', () {
      expect(resolve(''), isNull);
    });

    test('a spaces-only block is dropped by default', () {
      expect(resolve('   '), isNull);
    });

    test('a whitespace-only block survives with the opt-in', () {
      final result = resolve('\n\n', sendEmptyBlock: true);
      expect(result, isNotNull);
      expect(result!.content, '\n\n');
    });

    test('a block that macros expand down to whitespace is dropped', () {
      // {{summary}} resolves to nothing here, leaving only the newline the
      // author typed around it.
      expect(resolve('{{summary}}\n'), isNull);
    });

    test('a block that macros expand down to nothing is dropped', () {
      expect(resolve('{{summary}}'), isNull);
    });

    test('surrounding whitespace is preserved, not trimmed away', () {
      final result = resolve('\n  You are a helpful assistant.  \n');
      expect(result, isNotNull);
      expect(result!.content, '\n  You are a helpful assistant.  \n');
    });

    test('a setvar-only block resolves for accounting but is not sent', () {
      final result = resolve('{{setvar::flag::1}}');
      expect(result, isNotNull);
      expect(result!.content, isEmpty);
      expect(result.contentForAccounting, isNotEmpty);
    });

    test('a setvar-only block can explicitly emit an empty message', () {
      final result = resolve('{{setvar::flag::1}}', sendEmptyBlock: true);
      expect(result, isNotNull);
      expect(result!.content, isEmpty);
      expect(result.contentForAccounting, isNotEmpty);
    });
  });

  group('buildApiMessages', () {
    test('drops empty messages unless explicitly enabled', () {
      final messages = buildApiMessages(const [
        PromptMessage(role: 'system', content: 'kept'),
        PromptMessage(role: 'system', content: ''),
        PromptMessage(role: 'system', content: '   '),
        PromptMessage(role: 'system', content: '', sendEmptyBlock: true),
      ]);

      expect(messages, hasLength(2));
      expect(messages[0]['content'], 'kept');
      expect(messages[1]['content'], '');
    });

    test('does not trim the content it sends', () {
      final messages = buildApiMessages(const [
        PromptMessage(role: 'system', content: '\nmain prompt\n'),
      ]);

      expect(messages.single['content'], '\nmain prompt\n');
    });
  });
}
