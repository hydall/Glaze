import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_tag_utils.dart';
import 'package:glaze_flutter/features/extensions/services/extension_post_gen_service.dart';
import 'package:glaze_flutter/features/extensions/services/macro_expander.dart';
import 'package:glaze_flutter/features/extensions/services/rewrite/rewrite_service.dart';
import 'package:glaze_flutter/features/extensions/services/rewrite/search_replace_diff.dart';

void main() {
  group('search/replace diff', () {
    test('parses fenced hunks and applies them in order', () {
      const reply =
          '```\n'
          '<<<<<<< SEARCH\n'
          'the cat sat\n'
          '=======\n'
          'the dog sat\n'
          '>>>>>>> REPLACE\n'
          '\n'
          '<<<<<<< SEARCH\n'
          'on the mat\n'
          '=======\n'
          '>>>>>>> REPLACE\n'
          '```';
      final hunks = parseSearchReplaceDiff(reply);
      expect(hunks, hasLength(2));
      expect(hunks[1].replace, '');

      final applied = applySearchReplaceDiff(
        'So the cat sat on the mat.',
        hunks,
      );
      expect(applied.text, 'So the dog sat .');
      expect(applied.appliedCount, 2);
    });

    test('keeps CRLF line endings of the source', () {
      final applied = applySearchReplaceDiff('a\r\nb\r\nc', const [
        SearchReplaceHunk(search: 'a\nb', replace: 'x\ny'),
      ]);
      expect(applied.text, 'x\r\ny\r\nc');
    });

    test('rejects text outside hunks, missing markers and empty searches', () {
      Matcher fails(String code) => throwsA(
        isA<SearchReplaceDiffError>().having((e) => e.code, 'code', code),
      );
      expect(() => parseSearchReplaceDiff('   '), fails('EMPTY_DIFF'));
      expect(
        () => parseSearchReplaceDiff('Sure!'),
        fails('UNEXPECTED_CONTENT'),
      );
      expect(
        () => parseSearchReplaceDiff('<<<<<<< SEARCH\nx\n=======\ny'),
        fails('MALFORMED_HUNK'),
      );
      expect(
        () => parseSearchReplaceDiff(
          '<<<<<<< SEARCH\n=======\ny\n>>>>>>> REPLACE',
        ),
        fails('EMPTY_SEARCH'),
      );
    });

    test('refuses a missing or ambiguous search', () {
      Matcher fails(String code) => throwsA(
        isA<SearchReplaceDiffError>().having((e) => e.code, 'code', code),
      );
      expect(
        () => applySearchReplaceDiff('abc', const [
          SearchReplaceHunk(search: 'z', replace: ''),
        ]),
        fails('SEARCH_NOT_FOUND'),
      );
      expect(
        () => applySearchReplaceDiff('aa', const [
          SearchReplaceHunk(search: 'a', replace: 'b'),
        ]),
        fails('AMBIGUOUS_SEARCH'),
      );
    });

    test('recognises a no-changes reply', () {
      expect(isSearchReplaceNoChanges('NO_CHANGES'), isTrue);
      expect(isSearchReplaceNoChanges('```\nNO_CHANGES\n```'), isTrue);
      expect(isSearchReplaceNoChanges('No changes needed.'), isTrue);
      expect(isSearchReplaceNoChanges('NO_CHANGES\nbut also this'), isFalse);
      expect(
        isSearchReplaceNoChanges(
          '<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE',
        ),
        isFalse,
      );
    });
  });

  group('block tag utils', () {
    test('finds the first block, tags included', () {
      expect(
        blockFromMessage('x <info>a</info> <info>b</info>', 'info'),
        '<info>a</info>',
      );
      expect(blockFromMessage('nothing here', 'info'), '');
    });

    test('joins the trimmed content of every block', () {
      expect(
        multiBlockContentFromMessage(
          '<rewritten text>\n one \n</rewritten text> and '
              '<rewritten text>two</rewritten text>',
          'rewritten text',
        ),
        'one\ntwo',
      );
    });

    test('matches a name with attributes by its bare closing tag', () {
      expect(
        blockFromMessage('<stat type="hp">10</stat>', 'stat type="hp"'),
        '<stat type="hp">10</stat>',
      );
    });
  });

  group('RewriteTarget', () {
    test('rewrites the whole message without a fragment', () {
      final target = RewriteTarget.resolve('hello world');
      expect(target.isRange, isFalse);
      expect(target.apply('hello world', 'bye'), 'bye');
    });

    test('rewrites a unique fragment and follows the replacement', () {
      const message = 'one two three';
      final target = RewriteTarget.resolve(message, textToRewrite: 'two');
      expect(target.isRange, isTrue);
      final once = target.apply(message, 'TWO!');
      expect(once, 'one TWO! three');
      expect(target.text, 'TWO!');
      expect(target.apply(once, '2'), 'one 2 three');
    });

    test('uses an exact range even when the fragment repeats', () {
      final target = RewriteTarget.resolve(
        'a b a',
        textToRewrite: 'a',
        range: (start: 4, end: 5),
      );
      expect(target.apply('a b a', 'z'), 'a b z');
    });

    test('refuses a missing, ambiguous or stale fragment', () {
      expect(
        () => RewriteTarget.resolve('abc', textToRewrite: 'z'),
        throwsStateError,
      );
      expect(
        () => RewriteTarget.resolve('a b a', textToRewrite: 'a'),
        throwsStateError,
      );
      expect(
        () => RewriteTarget.resolve(
          'abc',
          textToRewrite: 'b',
          range: (start: 0, end: 1),
        ),
        throwsStateError,
      );
    });
  });

  test('dynamic macros are inserted as they are', () {
    final out = expand(
      'Rewrite: {{textToRewrite}} for {{user}} ({{AdditionalPrompt}})',
      const MacroContext(
        persona: 'Ann',
        dynamicMacros: {
          'textToRewrite': 'hi {{user}}',
          'additionalPrompt': 'shorter',
        },
      ),
    );
    expect(out, 'Rewrite: hi {{user}} for Ann (shorter)');
  });

  test('only independent carried scripts take a before/after phase', () {
    const base = BlockConfig(id: 's', name: 's', type: BlockType.script);
    expect(isPhasedScript(base.copyWith(source: BlockSource.carried)), isTrue);
    expect(
      isPhasedScript(
        base.copyWith(source: BlockSource.carried, dependsOnPrevious: true),
      ),
      isFalse,
    );
    expect(isPhasedScript(base.copyWith(source: BlockSource.model)), isFalse);
    expect(
      isPhasedScript(
        const BlockConfig(id: 'r', name: 'r', type: BlockType.rewrite),
      ),
      isFalse,
    );
    expect(BlockType.rewrite.isRunnable, isTrue);
    expect(BlockType.rewrite.hasPanelResult, isFalse);
  });

  test('a rewrite outcome keeps the source on no changes', () {
    const outcome = RewriteOutcome(
      text: 'same',
      mode: RewriteMode.searchReplace,
      noChanges: true,
    );
    expect(outcome.noChanges, isTrue);
  });
}
