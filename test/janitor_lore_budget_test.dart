import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_field_diff.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_lore_budget.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_separate.dart';

/// One token per non-blank character keeps the arithmetic readable.
final _budget = JanitorLoreBudget(
  (t) => t.replaceAll(RegExp(r'\s'), '').length,
);

Map<String, dynamic> payload({String persona = 'Anna.', String tail = ''}) => {
  'messages': [
    {
      'role': 'system',
      'content':
          "[System note]\n<Anna's Persona>\n$persona\n</Anna's Persona>\n"
          '<Scenario>\nThe library.\n</Scenario>\n$tail',
    },
  ],
};

void main() {
  group('JanitorLoreBudget.loreTokens', () {
    test('counts the text outside the wrapper blocks', () {
      final lore = 'x' * 500;
      expect(_budget.loreTokens(payload(tail: lore)), lore.length);
    });

    test('adds what the wrappers grew by since the probe', () {
      final probe = payload();
      final capture = payload(persona: 'Anna.\n${'y' * 300}', tail: 'z' * 200);
      expect(_budget.loreTokens(capture, probe: probe), 200 + 300);
    });

    test('a wrapper that shrank does not subtract lore', () {
      final probe = payload(persona: 'Anna. ${'y' * 300}');
      expect(_budget.loreTokens(payload(tail: 'z' * 50), probe: probe), 50);
    });

    test('is saturated within the margin below the cap', () {
      final near = janitorLoreTokenCap - janitorLoreSaturationMargin;
      expect(_budget.isSaturated(payload(tail: 'z' * near)), isTrue);
      expect(_budget.isSaturated(payload(tail: 'z' * (near - 1))), isFalse);
    });
  });

  group('splitTrigger', () {
    test('cuts on paragraphs into halves of about equal length', () {
      final parts = splitTrigger('aaaa\n\nbbbb\n\ncccc\n\ndddd');
      expect(parts, ['aaaa\n\nbbbb', 'cccc\n\ndddd']);
    });

    test('keeps a long paragraph whole on its own side', () {
      final long = 'L' * 100;
      expect(splitTrigger('a\n\n$long\n\nb'), ['a\n\n$long', 'b']);
    });

    test('falls back to lines, then sentences, then words', () {
      expect(splitTrigger('one\ntwo'), ['one', 'two']);
      expect(splitTrigger('First one. Second one.'), [
        'First one.',
        'Second one.',
      ]);
      expect(splitTrigger('alpha beta'), ['alpha', 'beta']);
    });

    test('a single word cannot be split', () {
      expect(splitTrigger('  Anna  '), ['Anna']);
    });

    test('halves keep every unit', () {
      const text = 'p1 line\np1 more\n\np2\n\np3 has. Two sentences.';
      final parts = splitTrigger(text);
      expect(parts, hasLength(2));
      expect(parts.join('\n\n'), text);
    });
  });

  group('mergeLorebookTexts', () {
    test('keeps each block once, in first-seen order', () {
      expect(
        mergeLorebookTexts([
          'Entry A\n\nEntry B',
          'entry   b\n\nEntry C',
          '',
          'Entry A',
        ]),
        'Entry A\n\nEntry B\n\nEntry C',
      );
    });
  });

  group('scanInjectedFields with split passes', () {
    test('recovers field lore from every pass, once', () {
      const base = 'Anna is a librarian.';
      const loreA = 'The library hides a sealed basement archive.';
      const loreB = 'Anna once served in the royal cartography corps.';
      final scan = scanInjectedFields(
        probe: const PromptFields(persona: base),
        capture: const PromptFields(persona: '$base\n$loreA'),
        extraCaptures: const [
          PromptFields(persona: '$base\n$loreA'),
          PromptFields(persona: '$base\n$loreB'),
        ],
      );
      expect(scan.blocks.map((b) => b.text), [loreA, loreB]);
    });
  });
}
