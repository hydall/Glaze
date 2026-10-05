import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/tts/services/tts_text_preparer.dart';

void main() {
  const plain = TtsTextOptions();

  List<String> texts(String raw, TtsTextOptions o) =>
      TtsTextPreparer.prepare(raw, o).map((s) => s.text).toList();

  group('cleaning', () {
    test('removes asterisks but keeps their text by default', () {
      expect(texts('*smiles* "Hi there."', plain), ['smiles "Hi there."']);
    });

    test('drops asterisk passages when ignoring them', () {
      expect(
        texts('*smiles* "Hi there."', const TtsTextOptions(ignoreAsterisks: true)),
        ['"Hi there."'],
      );
    });

    test('keeps asterisks when passing them through', () {
      expect(
        texts('*smiles*', const TtsTextOptions(passAsterisks: true)),
        ['*smiles*'],
      );
    });

    test('skips code blocks', () {
      expect(texts('Look:\n```dart\nprint(1);\n```\nDone.', plain), [
        'Look: Done.',
      ]);
    });

    test('skips paired tags with their content only when asked', () {
      const raw = 'Hello <status>HP 10</status> world';
      expect(texts(raw, plain), ['Hello HP 10 world']);
      expect(texts(raw, const TtsTextOptions(skipTags: true)), ['Hello world']);
    });

    test('drops images and keeps link labels', () {
      expect(texts('![pic](a.png) See [docs](http://x).', plain), ['See docs.']);
    });

    test('applies the user regex', () {
      expect(
        texts('Hello [OOC: note] world', const TtsTextOptions(regexPattern: r'/\[ooc:.*?\]/i')),
        ['Hello world'],
      );
    });

    test('returns nothing for text without letters', () {
      expect(texts('*** --- ...', plain), isEmpty);
    });
  });

  group('quotes only', () {
    test('joins quoted passages with the separator', () {
      expect(
        TtsTextPreparer.joinQuotedBlocks('She said "hi" and «bye».'),
        '"hi" ... «bye»',
      );
    });

    test('keeps nested quotes inside the outer pair', () {
      expect(
        TtsTextPreparer.joinQuotedBlocks('“He said ‘no’ to me” she said'),
        '“He said ‘no’ to me”',
      );
    });

    test('returns text unchanged without quotes', () {
      expect(TtsTextPreparer.joinQuotedBlocks('No quotes here'), 'No quotes here');
    });
  });

  group('segments', () {
    test('splits dialogue, actions and narration', () {
      final segments = TtsTextPreparer.splitSegments(
        'She waves. *smiles* "Hello!" Then leaves.',
      );
      expect(segments.map((s) => s.type), [
        TtsSegmentType.other,
        TtsSegmentType.action,
        TtsSegmentType.dialogue,
        TtsSegmentType.other,
      ]);
      expect(segments[2].text, 'Hello!');
    });

    test('multi-voice keeps action type after asterisks are removed', () {
      final segments = TtsTextPreparer.prepare(
        '*smiles* "Hi"',
        const TtsTextOptions(multiVoice: true),
      );
      expect(segments, const [
        TtsSegment(TtsSegmentType.action, 'smiles'),
        TtsSegment(TtsSegmentType.dialogue, 'Hi'),
      ]);
    });

    test('paragraph mode makes one segment per line', () {
      expect(
        texts('First line.\n\nSecond line.', const TtsTextOptions(narrateByParagraphs: true)),
        ['First line.', 'Second line.'],
      );
    });
  });

  test('parseUserRegex rejects invalid patterns', () {
    expect(TtsTextPreparer.parseUserRegex('('), isNull);
    expect(TtsTextPreparer.parseUserRegex('/abc/i')!.isCaseSensitive, isFalse);
  });
}
