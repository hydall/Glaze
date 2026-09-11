import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/import/st_lorebook_importer.dart';
import 'package:glaze_flutter/core/llm/glaze_matcher.dart';
import 'package:glaze_flutter/core/llm/lorebook_scanner.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  group('parseRegexKey', () {
    test('strips delimiters and parses flags', () {
      final parsed = parseRegexKey('/abc/gi');
      expect(parsed, isNotNull);
      expect(parsed!.pattern, 'abc');
      expect(parsed.ignoreCase, isTrue);
      expect(parsed.multiLine, isFalse);
      expect(parsed.dotAll, isFalse);
    });

    test('accepts a regex key with no flags', () {
      expect(parseRegexKey('/abc/')?.pattern, 'abc');
    });

    test('leaves plain keys alone', () {
      expect(parseRegexKey('Kenta'), isNull);
      expect(parseRegexKey('AC/DC'), isNull);
      expect(parseRegexKey('/'), isNull);
    });

    test('a trailing segment that is not a flag list stays literal', () {
      expect(parseRegexKey('/home/user'), isNull);
    });
  });

  group('glazeCheckMatch with /pattern/flags keys', () {
    test('matches a Cyrillic ST regex key against lowercased scan text', () {
      const key = r'/(?:^|[^а-яА-ЯёЁ])Кент(?:а|ой|у)(?:[^а-яА-ЯёЁ]|)/g';
      expect(
        glazeCheckMatch(
          key,
          'привет, кента, как дела?',
          false,
          WholeWordMode.no,
        ),
        isTrue,
      );
      expect(
        glazeCheckMatch(
          key,
          'ничего похожего тут нет',
          false,
          WholeWordMode.no,
        ),
        isFalse,
      );
    });

    test('whole-word modes do not wrap a regex key', () {
      const key = r'/(?:^|[^а-яА-ЯёЁ])Осак(?:а|и|е|у|ой)?/g';
      for (final mode in WholeWordMode.values) {
        expect(
          glazeCheckMatch(key, 'мы в осаке', false, mode),
          isTrue,
          reason: 'failed for $mode',
        );
      }
    });

    test('the i flag overrides a case-sensitive entry', () {
      expect(
        glazeCheckMatch('/kenta/i', 'Kenta', true, WholeWordMode.no),
        isTrue,
      );
      expect(
        glazeCheckMatch('/kenta/g', 'Kenta', true, WholeWordMode.no),
        isFalse,
      );
    });

    test('the s flag lets . cross newlines', () {
      expect(
        glazeCheckMatch('/a.b/s', 'a\nb', false, WholeWordMode.no),
        isTrue,
      );
      expect(
        glazeCheckMatch('/a.b/g', 'a\nb', false, WholeWordMode.no),
        isFalse,
      );
    });

    test('an uncompilable regex key falls back to a literal match', () {
      expect(
        glazeCheckMatch(
          '/(unclosed/g',
          'text with /(unclosed/g inside',
          false,
          WholeWordMode.no,
        ),
        isTrue,
      );
    });

    test('a pathological regex key falls back to a literal match', () {
      // ReDoS guard: the pattern is never compiled, so the key can only match
      // as text (it does not appear in the message).
      expect(
        glazeCheckMatch(r'/(a+)+$/g', '${'a' * 22}!', false, WholeWordMode.no),
        isFalse,
      );
    });

    test('bare patterns keep working as before', () {
      expect(
        glazeCheckMatch(
          'Kenta',
          'meeting kenta today',
          false,
          WholeWordMode.no,
        ),
        isTrue,
      );
      expect(
        glazeCheckMatch('(cat|dog)', 'a dog barks', false, WholeWordMode.no),
        isTrue,
      );
    });
  });

  group('glazeCheckMatch whole words', () {
    test('matches a standalone Cyrillic literal', () {
      expect(
        glazeCheckMatch(
          'Стеллу',
          'Я встретил Стеллу.',
          false,
          WholeWordMode.yes,
        ),
        isTrue,
      );
    });

    test('does not match a Cyrillic literal inside another word', () {
      expect(
        glazeCheckMatch(
          'Вера',
          'Проверка завершена.',
          false,
          WholeWordMode.yes,
        ),
        isFalse,
      );
    });

    test('preserves whole-word matching for Latin literals', () {
      expect(
        glazeCheckMatch('Vera', 'Vera arrived.', false, WholeWordMode.yes),
        isTrue,
      );
      expect(
        glazeCheckMatch('Vera', 'Several arrived.', false, WholeWordMode.yes),
        isFalse,
      );
    });
  });

  group('splitLorebookKeys', () {
    test('splits plain keys on commas', () {
      expect(splitLorebookKeys('a, b ,c'), ['a', 'b', 'c']);
    });

    test('keeps a comma inside a regex key intact', () {
      expect(splitLorebookKeys(r'/Кент(?:а|у){1,2}/g, Kenta'), [
        r'/Кент(?:а|у){1,2}/g',
        'Kenta',
      ]);
    });

    test('keeps a comma inside a character class intact', () {
      expect(splitLorebookKeys(r'/[a,b]+/g, plain'), [r'/[a,b]+/g', 'plain']);
    });

    test('an escaped slash does not close the regex early', () {
      expect(splitLorebookKeys(r'/a\/b,c/g'), [r'/a\/b,c/g']);
    });

    test('drops empty segments', () {
      expect(splitLorebookKeys('a,,  , b'), ['a', 'b']);
    });
  });

  test('ST lorebook with /pattern/g keys activates on a Russian message', () {
    final imported = importSTLorebook({
      'name': 'Regex book',
      'entries': {
        '0': {
          'uid': 0,
          'key': [
            r'/(?:^|[^а-яА-ЯёЁ])Кент(?:а|ой|у)(?:[^а-яА-ЯёЁ]|)/g',
            '/Kenta/g',
          ],
          'keysecondary': <String>[],
          'comment': 'NPC - Takahashi Kenta',
          'content': 'KENTA_ENTRY',
          'constant': false,
          'selectiveLogic': 1,
          'order': 1,
          'position': 0,
          'disable': false,
        },
      },
    });

    final scanned = scanLorebooks(
      history: const [
        ChatMessage(id: 'm1', role: 'user', content: 'Что там с Кентой?'),
      ],
      char: null,
      textToScan: '',
      chatId: null,
      lorebooks: [imported.lorebook],
      globalSettings: const LorebookGlobalSettings(),
      activations: const LorebookActivations(),
    );

    expect(scanned.map((e) => e.content), ['KENTA_ENTRY']);
  });
}
