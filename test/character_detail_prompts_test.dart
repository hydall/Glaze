import 'package:flutter/material.dart';
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

  group('measureHeroName', () {
    const name = 'My College Scholarship Depends on Managing These Assets';
    const style = TextStyle(fontSize: 22, fontWeight: FontWeight.w700);

    ({double viewport, double overflow}) measure({
      required double maxWidth,
      required TextScaler scale,
      TextStyle textStyle = style,
    }) => measureHeroName(
      name: name,
      style: textStyle,
      maxWidth: maxWidth,
      textDirection: TextDirection.ltr,
      textScaler: scale,
    );

    test('a name that fits within the capped lines does not overflow', () {
      final layout = measure(maxWidth: 4000, scale: TextScaler.noScaling);
      expect(layout.overflow, lessThanOrEqualTo(0.5));
    });

    test('a scaled-up name is measured at the scaled height', () {
      // Regression: the painter previously ran without the ambient textScaler,
      // so the clip viewport used the unscaled line height and sliced the
      // second line once the system font was enlarged.
      final unscaled = measure(maxWidth: 360, scale: TextScaler.noScaling);
      final scaled = measure(maxWidth: 360, scale: const TextScaler.linear(2));

      expect(scaled.viewport, greaterThan(unscaled.viewport));
      expect(scaled.overflow, greaterThan(unscaled.overflow));
    });

    test('an inherited line height is part of the measurement', () {
      final plain = measure(maxWidth: 360, scale: TextScaler.noScaling);
      final tall = measure(
        maxWidth: 360,
        scale: TextScaler.noScaling,
        textStyle: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 2,
        ),
      );

      expect(tall.viewport, greaterThan(plain.viewport));
    });
  });
}
