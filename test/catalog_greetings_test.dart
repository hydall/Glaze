import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/chub_provider.dart';
import 'package:glaze_flutter/features/catalog/services/datacat_provider.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_provider.dart';

/// #98 at the layer it was reported from: a card downloaded through a catalog
/// provider, and which greeting ends up in which slot.
void main() {
  group('DataCat (#98 — "datacat skips the 1st greeting")', () {
    test('a row with the set in first_messages and nothing singular', () {
      // The shape the reporter hit. DataCat mirrors Janitor rows, so the whole
      // set can arrive in the plural field with `first_message` empty; reading
      // only the singular one left the opening line blank and shifted every
      // greeting down by one.
      final card = datacatCharacterData({
        'name': 'Mira',
        'first_message': '',
        'first_messages': ['the opening line', 'an alternate'],
      });
      expect(card.firstMes, 'the opening line');
      expect(card.alternateGreetings, ['an alternate']);
    });

    test('a row with both keeps the singular field as the opening line', () {
      final card = datacatCharacterData({
        'name': 'Mira',
        'first_message': 'the opening line',
        'alternate_greetings': ['an alternate', 'another'],
      });
      expect(card.firstMes, 'the opening line');
      expect(card.alternateGreetings, ['an alternate', 'another']);
    });

    test('a set that repeats the opening line does not list it twice', () {
      final card = datacatCharacterData({
        'name': 'Mira',
        'first_message': 'the opening line',
        'first_messages': ['the opening line', 'an alternate'],
      });
      expect(card.firstMes, 'the opening line');
      expect(card.alternateGreetings, ['an alternate']);
    });

    test('the V2 blob is still read when the row itself carries nothing', () {
      final card = datacatCharacterData({
        'name': 'Mira',
        'chara_card_v2_json': {
          'data': {
            'first_mes': 'from the v2 blob',
            'alternate_greetings': ['also from the blob'],
          },
        },
      });
      expect(card.firstMes, 'from the v2 blob');
      expect(card.alternateGreetings, ['also from the blob']);
    });

    test('a card with no greeting at all maps to an empty one', () {
      final card = datacatCharacterData({'name': 'Mira'});
      expect(card.firstMes, '');
      expect(card.alternateGreetings, isEmpty);
    });
  });

  group('JanitorAI', () {
    test('first_messages no longer repeats the opening line', () {
      // `first_messages` is the whole set *including* `first_message`, so
      // mapping it straight onto the alternates listed that greeting twice.
      final card = janitorCharacterFromMeta({
        'name': 'Mira',
        'first_message': 'the opening line',
        'first_messages': ['the opening line', 'an alternate', 'a third'],
      });
      expect(card.charData.firstMes, 'the opening line');
      expect(card.charData.alternateGreetings, ['an alternate', 'a third']);
    });

    test('a card carrying only the set still opens on its first greeting', () {
      final card = janitorCharacterFromMeta({
        'name': 'Mira',
        'first_messages': ['the opening line', 'an alternate'],
      });
      expect(card.charData.firstMes, 'the opening line');
      expect(card.charData.alternateGreetings, ['an alternate']);
    });
  });

  group('Chub', () {
    test('a node with both fields is unchanged', () {
      final card = chubCharacterData({
        'name': 'Mira',
        'definition': {
          'first_message': 'the opening line',
          'alternate_greetings': ['an alternate'],
        },
      });
      expect(card.firstMes, 'the opening line');
      expect(card.alternateGreetings, ['an alternate']);
    });

    test('a node with an empty first_message promotes its first alternate', () {
      final card = chubCharacterData({
        'name': 'Mira',
        'definition': {
          'first_message': '',
          'alternate_greetings': ['the opening line', 'an alternate'],
        },
      });
      expect(card.firstMes, 'the opening line');
      expect(card.alternateGreetings, ['an alternate']);
    });
  });
}
