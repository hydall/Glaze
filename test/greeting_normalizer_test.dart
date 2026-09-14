import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/greeting_normalizer.dart';

/// Providers disagree about where a card's greetings live, and #98 is what that
/// disagreement looks like to a reader: DataCat "skips the 1st greeting" on
/// some cards, while downloading the same card from DataCat's own site does
/// not. The rule is stated once now, so these are the rule.
void main() {
  group('normalizeGreetings', () {
    test('an ordinary card keeps its opening line and its alternates', () {
      final result = normalizeGreetings(
        primary: 'hello there',
        others: ['a second one', 'a third'],
      );
      expect(result.firstMes, 'hello there');
      expect(result.alternates, ['a second one', 'a third']);
    });

    test('#98 — a blank singular field promotes the first of the set', () {
      // The DataCat shape: the row carries the whole set and nothing in
      // `first_message`. Reading only the singular field left slot one blank
      // and shifted every greeting down by one.
      final result = normalizeGreetings(
        primary: '',
        others: ['the real opening line', 'an alternate'],
      );
      expect(result.firstMes, 'the real opening line');
      expect(result.alternates, ['an alternate']);
    });

    test('a set that repeats the opening line does not list it twice', () {
      // The JanitorAI shape: `first_messages` is the whole set *including*
      // `first_message`.
      final result = normalizeGreetings(
        primary: 'hello there',
        others: ['hello there', 'a second one'],
      );
      expect(result.firstMes, 'hello there');
      expect(result.alternates, ['a second one']);
    });

    test('order is the author\'s, never sorted', () {
      final result = normalizeGreetings(
        primary: 'zebra',
        others: ['apple', 'mango'],
      );
      expect(result.firstMes, 'zebra');
      expect(result.alternates, ['apple', 'mango']);
    });

    test('blanks, whitespace and nulls drop out', () {
      final result = normalizeGreetings(
        primary: null,
        others: ['   ', '', null, 'the only one', '\n\t'],
      );
      expect(result.firstMes, 'the only one');
      expect(result.alternates, isEmpty);
    });

    test('greetings are trimmed, and trimming is what dedupes them', () {
      final result = normalizeGreetings(
        primary: '  hello  ',
        others: ['hello', '  hello\n'],
      );
      expect(result.firstMes, 'hello');
      expect(result.alternates, isEmpty);
    });

    test('a card with no greeting at all is empty, not a crash', () {
      final result = normalizeGreetings();
      expect(result.firstMes, '');
      expect(result.alternates, isEmpty);
    });

    test('one greeting leaves no alternates', () {
      final result = normalizeGreetings(primary: 'just the one');
      expect(result.firstMes, 'just the one');
      expect(result.alternates, isEmpty);
    });

    test('the alternates cannot be written through', () {
      final result = normalizeGreetings(
        primary: 'a',
        others: ['b'],
      );
      expect(() => result.alternates.add('c'), throwsUnsupportedError);
    });
  });

  group('greetingList', () {
    test('takes the strings out of a list', () {
      expect(greetingList(['a', 'b']), ['a', 'b']);
    });

    test('ignores what is not a string, rather than throwing on it', () {
      expect(greetingList(['a', 1, null, {'b': 'c'}, 'd']), ['a', 'd']);
    });

    test('a null, an empty list and a non-list are all nothing', () {
      expect(greetingList(null), isEmpty);
      expect(greetingList(const []), isEmpty);
      expect(greetingList('not a list'), isEmpty);
      expect(greetingList(42), isEmpty);
    });
  });
}
