import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/extensions/services/macro_expander.dart';

void main() {
  group('MacroExpander.expand', () {
    test('empty text is returned as-is', () {
      expect(expand('', MacroContext.empty), '');
    });

    test('text without placeholders is returned unchanged', () {
      const text = 'Hello, world!';
      expect(expand(text, MacroContext.empty), text);
    });

    test('replaces {{char}} with character name', () {
      final ctx = MacroContext(
        character: _character(name: 'Alise', description: 'A witch'),
      );
      expect(expand('Hi from {{char}}!', ctx), 'Hi from Alise!');
    });

    test('replaces {{user}} with persona name', () {
      final ctx = MacroContext(persona: 'Иван');
      expect(expand('Greetings, {{user}}.', ctx), 'Greetings, Иван.');
    });

    test('replaces {{description}} with character description', () {
      final ctx = MacroContext(
        character: _character(description: 'stern, clever'),
      );
      expect(expand('She is {{description}}.', ctx), 'She is stern, clever.');
    });

    test('replaces {{personality}} with character personality', () {
      final ctx = MacroContext(
        character: _character(personality: 'outgoing'),
      );
      expect(expand('Personality: {{personality}}', ctx),
          'Personality: outgoing');
    });

    test('replaces {{scenario}} with character scenario', () {
      final ctx = MacroContext(
        character: _character(scenario: 'a quiet village'),
      );
      expect(expand('Setting: {{scenario}}', ctx), 'Setting: a quiet village');
    });

    test('case-insensitive replacement', () {
      final ctx = MacroContext(
        character: _character(name: 'Alise'),
        persona: 'Иван',
      );
      expect(expand('{{CHAR}} meets {{User}}.', ctx), 'Alise meets Иван.');
    });

    test('multiple placeholders in one string', () {
      final ctx = MacroContext(
        character: _character(
          name: 'Alise',
          description: 'a witch',
          personality: 'reserved',
          scenario: 'festival',
        ),
        persona: 'Иван',
      );
      final out = expand(
        '{{char}} is {{description}}, {{personality}} in {{scenario}}, '
        'meeting {{user}}.',
        ctx,
      );
      expect(
        out,
        'Alise is a witch, reserved in festival, meeting Иван.',
      );
    });

    test('missing character fields expand to empty string', () {
      const ctx = MacroContext.empty;
      expect(expand('{{char}} {{user}} {{description}}', ctx), '  ');
    });

    test('null persona expands {{user}} to empty string', () {
      final ctx = MacroContext(character: _character(name: 'Alise'));
      expect(expand('{{user}} saw {{char}}.', ctx), ' saw Alise.');
    });

    test('no regex special-char issues (replaces literal braces)', () {
      // Ensures RegExp.escape is used internally — no special chars
      // in placeholders are interpreted as regex.
      final ctx = MacroContext(persona: 'a.b.c');
      expect(expand('{{user}}', ctx), 'a.b.c');
    });

    test('text containing only the same braces as placeholder is preserved', () {
      // The placeholder is "{{user}}", not just "{user}". We must not
      // strip user-typed text that contains single braces.
      final ctx = MacroContext(persona: 'Иван');
      expect(expand('The formula is {x} + {y}.', ctx), 'The formula is {x} + {y}.');
    });
  });

  group('MacroContext.empty', () {
    test('is a const instance with null fields', () {
      expect(MacroContext.empty.character, isNull);
      expect(MacroContext.empty.persona, isNull);
    });

    test('expands to empty strings for all known placeholders', () {
      final out = expand('{{char}}/{{user}}/{{description}}', MacroContext.empty);
      expect(out, '//');
    });
  });
}

Character _character({
  String? name,
  String? description,
  String? personality,
  String? scenario,
}) {
  return Character(
    id: 'char_id',
    name: name ?? 'Test',
    description: description,
    personality: personality,
    scenario: scenario,
    createdAt: 0,
    updatedAt: 0,
  );
}
