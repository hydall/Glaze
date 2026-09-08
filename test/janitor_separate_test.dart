import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_separate.dart';

/// A synthetic JanitorAI `generateAlpha` payload: jailbreak prefix + character
/// persona + user persona + scenario + two concatenated lorebook entry blocks.
Map<String, dynamic> _payload() => {
      'model': 'test',
      'messages': [
        {
          'role': 'system',
          'content': '[Start a new chat][System: roleplay mode]\n'
              "<Aria's Persona>\n"
              'Aria is a knight of the northern keep. She is stoic and loyal.\n'
              "</Aria's Persona>\n"
              '<UserPersona>\n'
              'You are a traveling merchant named Cole.\n'
              '</UserPersona>\n'
              '<Scenario>\n'
              'A storm traps both travelers in a mountain inn.\n'
              '</Scenario>\n'
              'The Northern Keep is an ancient fortress carved into the cliffs. '
              'It has stood for a thousand winters.\n'
              '\n'
              'The Frostfang Blade is a legendary sword said to never dull. '
              'Only the worthy may wield it.',
        },
        {
          'role': 'assistant',
          'content': 'Aria nods at you from across the fire. "Cold night."',
        },
      ],
    };

void main() {
  group('janitor_separate', () {
    final payload = _payload();

    test('extractCard returns the character persona, not the user persona', () {
      final card = extractCard(payload);
      expect(card, contains('knight of the northern keep'));
      expect(card, isNot(contains('traveling merchant')));
    });

    test('extractCharName strips the possessive', () {
      expect(extractCharName(payload), 'Aria');
    });

    test('extractScenario / extractFirstMessage', () {
      expect(extractScenario(payload), contains('storm traps'));
      expect(extractFirstMessage(payload), contains('Cold night'));
    });

    test('separate isolates the lorebook text and splits into blocks', () {
      final sep = separate(payload, extractCard(payload));

      // Wrappers gone.
      expect(sep.lorebookText, isNot(contains('Persona')));
      expect(sep.lorebookText, isNot(contains('Scenario')));
      expect(sep.lorebookText, isNot(contains('Start a new chat')));
      expect(sep.lorebookText, isNot(contains('traveling merchant')));

      // Lorebook content kept.
      expect(sep.lorebookText, contains('Northern Keep'));
      expect(sep.lorebookText, contains('Frostfang Blade'));

      // Two distinct entry blocks.
      expect(sep.entries.length, 2);
      expect(sep.entries[0], contains('Northern Keep'));
      expect(sep.entries[1], contains('Frostfang Blade'));

      // Wrapper blocks were recorded as removed.
      final labels = sep.removed.map((r) => r.label).toSet();
      expect(labels, containsAll(<String>['jailbreak', 'card', 'userPersona', 'scenario']));
    });

    test('getSystemContent returns empty for a payload without a system msg', () {
      expect(getSystemContent(<String, dynamic>{'messages': <dynamic>[]}), '');
      expect(getSystemContent(const <String, dynamic>{}), '');
    });

    test('separate subtracts public-lorebook entry contents', () {
      // The Northern Keep entry is a PUBLIC lorebook entry — passed verbatim, it
      // must be cut from the closed lorebook so it never leaks in twice.
      final sep = separate(payload, extractCard(payload), [
        'The Northern Keep is an ancient fortress carved into the cliffs. '
            'It has stood for a thousand winters.',
      ]);
      expect(sep.lorebookText, isNot(contains('Northern Keep')));
      // The genuinely closed entry survives.
      expect(sep.lorebookText, contains('Frostfang Blade'));
      expect(sep.removed.map((r) => r.label), contains('publicLorebook'));
    });

    test('public-entry subtraction tolerates whitespace and glyph variants', () {
      // Same entry with collapsed whitespace and a curly apostrophe / en dash.
      final sep = separate(payload, extractCard(payload), [
        'The   Northern Keep is an ancient fortress carved into the cliffs.\n'
            'It has stood for a thousand winters.',
      ]);
      expect(sep.lorebookText, isNot(contains('Northern Keep')));
    });
  });
}
