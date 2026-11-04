import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_lorebook_rebuilder.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

void main() {
  String entry(int i, {int words = 200}) =>
      'Entry $i. ${List.filled(words, 'lore$i').join(' ')}';

  group('lorebookBuildChunkBudget', () {
    test('a large window is capped at the per-request ceiling', () {
      expect(
        lorebookBuildChunkBudget(
          const ApiConfig(id: 'c', contextSize: 1000000),
        ),
        kDefaultLorebookBuildChunkTokens,
      );
    });

    test('a small window leaves room for the reply', () {
      expect(
        lorebookBuildChunkBudget(
          const ApiConfig(id: 'c', contextSize: 16000),
          fixedTokens: 2000,
        ),
        7000,
      );
    });

    test('never drops below the floor', () {
      expect(
        lorebookBuildChunkBudget(
          const ApiConfig(id: 'c', contextSize: 1000),
          fixedTokens: 5000,
        ),
        2000,
      );
    });
  });

  group('chunkLorebookText', () {
    test('text within the budget stays one piece', () {
      final text = [entry(1), entry(2)].join('\n\n');
      expect(chunkLorebookText(text, 100000), [text]);
    });

    test('splits between entries and keeps every entry whole', () {
      final entries = [for (var i = 0; i < 40; i++) entry(i)];
      final text = entries.join('\n\n');
      final budget = estimateTokens(text) ~/ 5;
      final chunks = chunkLorebookText(text, budget);

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(estimateTokens(chunk), lessThanOrEqualTo(budget + 40));
      }
      // Nothing lost, nothing reordered, no entry cut in two.
      expect(chunks.join('\n\n'), text);
      final rejoined = chunks.expand((c) => c.split('\n\n')).toList();
      expect(rejoined, entries);
    });

    test('a single oversized entry is cut on lines, then by length', () {
      final lines = [for (var i = 0; i < 50; i++) entry(i, words: 40)];
      final huge = lines.join('\n');
      final chunks = chunkLorebookText(huge, estimateTokens(huge) ~/ 4);
      expect(chunks.length, greaterThan(1));
      expect(chunks.join('\n'), huge);

      final line = List.filled(5000, 'word').join(' ');
      final pieces = chunkLorebookText(line, 500);
      expect(pieces.length, greaterThan(1));
      expect(pieces.join(), line);
    });
  });

  group('planLorebookBuild', () {
    test('every request carries the same context and its own slice', () {
      final text = [for (var i = 0; i < 300; i++) entry(i)].join('\n\n');
      final requests = planLorebookBuild(
        text,
        config: const ApiConfig(id: 'c', contextSize: 1000000),
        card: 'CARD TEXT',
      );
      expect(requests.length, greaterThan(1));
      for (final messages in requests) {
        expect(messages.first['role'], 'system');
        expect(messages.last['content'], contains('CARD TEXT'));
      }
    });

    test('the request size setting decides the split; 0 turns it off', () {
      final text = [for (var i = 0; i < 300; i++) entry(i)].join('\n\n');
      const config = ApiConfig(id: 'c', contextSize: 1000000);
      final small = planLorebookBuild(text, config: config, chunkTokens: 4000);
      final large = planLorebookBuild(text, config: config, chunkTokens: 60000);
      expect(small.length, greaterThan(large.length));
      expect(
        planLorebookBuild(text, config: config, chunkTokens: 0),
        hasLength(1),
      );
    });

    test('JavaScript source is never split', () {
      final text = [for (var i = 0; i < 300; i++) entry(i)].join('\n\n');
      final requests = planLorebookBuild(
        text,
        config: const ApiConfig(id: 'c', contextSize: 1000000),
        fromJs: true,
      );
      expect(requests, hasLength(1));
    });
  });
}
