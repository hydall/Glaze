import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/llm/tokenizers/pre_tokenizer.dart';
import 'package:glaze_flutter/core/llm/tokenizers/text_normalizer.dart';
import 'package:glaze_flutter/core/llm/tokenizers/tokenizer_codec.dart';

import 'tokenizer_fixtures.dart';

void main() {
  group('byte-level BPE', () {
    final tokenizer = tokenizerFromHfJson(byteLevelTokenizerJson());

    test('applies merges within each pre-tokenized piece', () {
      expect(tokenizer.count(''), 0);
      expect(tokenizer.count('hello'), 1);
      // " world": Ġw + o r l d.
      expect(tokenizer.count('hello world'), 6);
    });

    test('merges the lowest rank first, leftmost on ties', () {
      expect(tokenizer.count('lll'), 2);
      expect(tokenizer.count('llll'), 2);
    });

    test('splits multi-byte characters into their UTF-8 bytes', () {
      // h, é (two bytes), ll, o.
      expect(tokenizer.count('héllo'), 5);
    });

    test('honours the case-insensitive contraction group', () {
      // "it" is two bytes; "'S" is its own piece and one merge.
      expect(tokenizer.count("it'S"), 3);
    });
  });

  group('character BPE with byte fallback', () {
    final tokenizer = tokenizerFromHfJson(charLevelTokenizerJson());

    test('replaces spaces and merges across them', () {
      expect(tokenizer.count(' ab'), 1);
      expect(tokenizer.count(' abc'), 1);
      expect(tokenizer.count('ab ab'), 2);
    });

    test('falls back to bytes for characters outside the vocabulary', () {
      expect(tokenizer.count('é'), 2);
      expect(tokenizer.count('a😀'), 5);
    });

    test('short and long pieces agree with a reference BPE', () {
      final random = Random(7);
      const alphabet = [' ', 'a', 'b', 'c', 'é'];
      for (var round = 0; round < 300; round++) {
        final length = 1 + random.nextInt(round < 150 ? 48 : 400);
        final text = List.generate(
          length,
          (_) => alphabet[random.nextInt(alphabet.length)],
        ).join();
        expect(tokenizer.count(text), _referenceCount(text), reason: text);
      }
    });
  });

  group('cache codec', () {
    test('round-trips both tokenizer shapes', () {
      for (final json in [byteLevelTokenizerJson(), charLevelTokenizerJson()]) {
        final original = tokenizerFromHfJson(json);
        final bytes = encodeTokenizerCache(original);
        expect(
          isCurrentTokenizerCache(Uint8List.sublistView(bytes, 0, 16)),
          isTrue,
        );
        final restored = decodeTokenizerCache(bytes)!;
        for (final text in ['hello world', ' abc ab', 'héllo 😀', 'lll']) {
          expect(restored.count(text), original.count(text), reason: text);
        }
      }
    });

    test('rejects files that are not a current cache', () {
      expect(
        decodeTokenizerCache(Uint8List.fromList(utf8.encode('{}'))),
        isNull,
      );
      final bytes = encodeTokenizerCache(
        tokenizerFromHfJson(byteLevelTokenizerJson()),
      );
      ByteData.sublistView(bytes).setUint32(8, 999, Endian.little);
      expect(decodeTokenizerCache(bytes), isNull);
      expect(
        isCurrentTokenizerCache(Uint8List.sublistView(bytes, 0, 16)),
        isFalse,
      );
      expect(decodeTokenizerCache(Uint8List.sublistView(bytes, 0, 40)), isNull);
    });
  });

  group('pre-tokenizers', () {
    test('expands scoped case-insensitive groups', () {
      final regex = compileHfRegex(r"(?i:'s|'ll)|\p{L}+");
      expect(regex.allMatches("it'S we'LL").map((m) => m[0]).toList(), [
        'it',
        "'S",
        'we',
        "'LL",
      ]);
    });

    test('split behaviours', () {
      List<String> run(String behavior, {bool invert = false}) =>
          PreTokenizer.fromSpec({
            'type': 'Split',
            'pattern': {'String': '-'},
            'behavior': behavior,
            'invert': invert,
          })!.split(['a-b--c']);

      expect(run('Isolated'), ['a', '-', 'b', '-', '-', 'c']);
      expect(run('Removed'), ['a', 'b', 'c']);
      expect(run('MergedWithPrevious'), ['a-', 'b-', '-', 'c']);
      expect(run('MergedWithNext'), ['a', '-b', '-', '-c']);
      expect(run('Contiguous'), ['a', '-', 'b', '--', 'c']);
      expect(run('Removed', invert: true), ['-', '-', '-']);
    });

    test('metaspace replaces spaces and splits before them', () {
      final pre = PreTokenizer.fromSpec({
        'type': 'Metaspace',
        'replacement': '▁',
        'prepend_scheme': 'always',
        'split': true,
      })!;
      expect(pre.split(['hi there']), ['▁hi', '▁there']);
    });

    test('digits split on every numeric character, as HF does', () {
      final pre = PreTokenizer.fromSpec({
        'type': 'Digits',
        'individual_digits': true,
      })!;
      expect(pre.split(['a12b１２½']), ['a', '1', '2', 'b', '１', '２', '½']);
    });
  });

  group('normalizers', () {
    test('NFKC folds compatibility characters and composes marks', () {
      final nfkc = TextNormalizer.fromSpec({'type': 'NFKC'})!;
      expect(nfkc.apply('𝐀𝐁 ⓒ ＡＢ ﬁ …'), 'AB c AB fi ...');
      expect(nfkc.apply('e\u0301'), 'é');
      expect(nfkc.apply('plain ascii'), 'plain ascii');
    });

    test('NFC composes without folding compatibility characters', () {
      final nfc = TextNormalizer.fromSpec({'type': 'NFC'})!;
      expect(nfc.apply('e\u0301 ﬁ'), 'é ﬁ');
    });
  });

  group('estimateTokens', () {
    tearDown(() => debugSetActiveTokenizer(null, TokenizerKind.approx));

    test('counts with the installed tokenizer and forgets old counts', () {
      debugSetActiveTokenizer(null, TokenizerKind.approx);
      expect(activeTokenizerKind, TokenizerKind.approx);
      expect(estimateTokens('hello'), 2);

      debugSetActiveTokenizer(
        tokenizerFromHfJson(byteLevelTokenizerJson()),
        TokenizerKind.o200k,
      );
      expect(activeTokenizerKind, TokenizerKind.o200k);
      expect(estimateTokens('hello'), 1);
      expect(estimateTokens('hello world'), 6);
    });
  });
}

/// Straightforward string BPE over [charLevelMerges], written independently
/// of the engine: it is what the heap-based path must reproduce.
int _referenceCount(String text) {
  final ranks = {
    for (var i = 0; i < charLevelMerges.length; i++)
      '${charLevelMerges[i].$1}|${charLevelMerges[i].$2}': i,
  };
  final symbols = <String>[];
  for (final rune in text.replaceAll(' ', '▁').runes) {
    final ch = String.fromCharCode(rune);
    if (const {'▁', 'a', 'b', 'c'}.contains(ch)) {
      symbols.add(ch);
    } else {
      for (final b in utf8.encode(ch)) {
        symbols.add('<$b>');
      }
    }
  }
  while (true) {
    var best = -1;
    var bestRank = 1 << 30;
    for (var i = 0; i < symbols.length - 1; i++) {
      final rank = ranks['${symbols[i]}|${symbols[i + 1]}'];
      if (rank != null && rank < bestRank) {
        bestRank = rank;
        best = i;
      }
    }
    if (best < 0) return symbols.length;
    symbols[best] = symbols[best] + symbols[best + 1];
    symbols.removeAt(best + 1);
  }
}
