import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/character_list/character_detail_screen.dart';

void main() {
  Character char({String? firstMes, List<String> alternates = const []}) {
    return Character(
      id: 'c1',
      name: 'Someone',
      firstMes: firstMes,
      alternateGreetings: alternates,
    );
  }

  List<int> numbers(List<({int number, String text})> messages) =>
      [for (final m in messages) m.number];

  group('characterFirstMessages', () {
    test('numbers the first message 1 and the alternates after it', () {
      final messages = characterFirstMessages(
        char(firstMes: 'hello', alternates: ['second', 'third']),
      );

      expect(numbers(messages), [1, 2, 3]);
      expect([for (final m in messages) m.text], [
        'hello',
        'second',
        'third',
      ]);
    });

    test('an empty slot is dropped without renumbering the ones after it', () {
      // The editor addresses greetings by their slot, so the message it opens
      // as "#3" has to be the one the sheet calls "#3" — a card whose middle
      // greeting is blank must not slide the last one up into its number.
      final messages = characterFirstMessages(
        char(firstMes: 'hello', alternates: ['', 'third']),
      );

      expect(numbers(messages), [1, 3]);
      expect(messages.last.text, 'third');
    });

    test('an alternate keeps its slot when there is no first message', () {
      final messages = characterFirstMessages(
        char(alternates: ['second']),
      );

      expect(numbers(messages), [2]);
    });

    test('a character with nothing to say has no messages', () {
      expect(characterFirstMessages(char()), isEmpty);
      expect(characterFirstMessages(char(firstMes: '')), isEmpty);
    });
  });

  group('heroNameScrollOffset', () {
    double offset(double elapsedMs) => heroNameScrollOffset(
      elapsedMs: elapsedMs,
      overflow: 40,
      holdMs: 1000,
      scrollMs: 2000,
    );

    test('a name that fits never moves', () {
      expect(
        heroNameScrollOffset(
          elapsedMs: 1234,
          overflow: 0,
          holdMs: 1000,
          scrollMs: 2000,
        ),
        0,
      );
    });

    test('rests at the top, scrolls down, then rests at the bottom', () {
      expect(offset(0), 0);
      expect(offset(999), 0);
      expect(offset(2000), 20);
      expect(offset(3000), 40);
      expect(offset(3500), 40);
    });

    test('starts over from the top on the next cycle', () {
      // Top-to-bottom and back to the start, not a bounce: the name always
      // reads in the same direction.
      const cycle = 4000.0;
      expect(offset(cycle), 0);
      expect(offset(cycle + 2000), 20);
      expect(offset(cycle * 3 + 3500), 40);
    });
  });
}
