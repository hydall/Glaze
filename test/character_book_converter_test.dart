import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/character_book_converter.dart';

void main() {
  group('convertCharacterBook probability', () {
    test('uses top-level probability', () {
      final book = convertCharacterBook({
        'entries': [
          {
            'probability': 35,
            'extensions': {'probability': 80},
          },
        ],
      }, 'character');

      expect(book.entries.single.probability, 35);
    });

    test('falls back to extensions probability', () {
      final book = convertCharacterBook({
        'entries': [
          {
            'extensions': {'probability': 100},
          },
        ],
      }, 'character');

      expect(book.entries.single.probability, 100);
    });

    test('defaults missing probability to 100 percent', () {
      final book = convertCharacterBook({
        'entries': [<String, dynamic>{}],
      }, 'character');

      expect(book.entries.single.probability, 100);
    });
  });
}
