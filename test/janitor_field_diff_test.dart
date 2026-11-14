import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_field_diff.dart';

/// A captured `generateAlpha` payload, assembled the way JanitorAI assembles
/// one: a system message wrapping the card / scenario / examples, then the
/// character's opening line as an assistant turn.
Map<String, dynamic> payload({
  String persona = 'Anna is a librarian.\nShe is thirty.',
  String scenario = 'You meet Anna at the library.',
  String example = '<START>\nAnna: Hello.',
  String firstMessage = 'Anna looks up from her book.',
  String tail = '',
}) {
  final sys = StringBuffer()
    ..writeln('[System note: stay in character]')
    ..writeln("<Anna's Persona>")
    ..writeln(persona)
    ..writeln("</Anna's Persona>")
    ..writeln('<UserPersona>')
    ..writeln('{{user}} is a visitor.')
    ..writeln('</UserPersona>')
    ..writeln('<Scenario>')
    ..writeln(scenario)
    ..writeln('</Scenario>')
    ..writeln('<Example dialogs>')
    ..writeln(example)
    ..writeln('</Example dialogs>');
  if (tail.isNotEmpty) sys.writeln(tail);
  return {
    'messages': [
      {'role': 'system', 'content': sys.toString()},
      {'role': 'assistant', 'content': firstMessage},
      {'role': 'user', 'content': '.'},
    ],
  };
}

/// The lore a script writes into a field it does not own — long enough to clear
/// the noise floor, as real entries are.
const _loreA =
    'The Vaults lie beneath the library, sealed since the flood of 1837.';
const _loreB =
    'Marcus Vane runs the night watch and answers to no one in the city.';

void main() {
  group('scanInjectedFields', () {
    test('recovers lore the trigger fired into the scenario', () {
      final before = PromptFields.fromPayload(payload());
      final after = PromptFields.fromPayload(
        payload(scenario: 'You meet Anna at the library.\n$_loreA'),
      );

      final scan = scanInjectedFields(capture: after, probe: before);

      expect(scan.length, 1);
      expect(scan.blocks.single.field, InjectionField.scenario);
      expect(scan.blocks.single.text, _loreA);
    });

    // The separator drops the persona block whole, so an entry written into the
    // middle of it is the case the diff exists for.
    test('recovers lore written into the middle of the persona', () {
      final before = PromptFields.fromPayload(payload());
      final after = PromptFields.fromPayload(
        payload(persona: 'Anna is a librarian.\n$_loreA\nShe is thirty.'),
      );

      final scan = scanInjectedFields(capture: after, probe: before);

      expect(scan.blocks.single.field, InjectionField.persona);
      expect(scan.blocks.single.text, _loreA);
    });

    // The first message is an assistant turn: the separator never reads it at
    // all, so without the diff this lore is invisible.
    test('recovers lore appended to the first message', () {
      final before = PromptFields.fromPayload(payload());
      final after = PromptFields.fromPayload(
        payload(firstMessage: 'Anna looks up from her book.\n\n$_loreB'),
      );

      final scan = scanInjectedFields(capture: after, probe: before);

      expect(scan.blocks.single.field, InjectionField.firstMessage);
      expect(scan.blocks.single.text, _loreB);
    });

    test('reports every field a single trigger wrote into', () {
      final before = PromptFields.fromPayload(payload());
      final after = PromptFields.fromPayload(payload(
        scenario: 'You meet Anna at the library.\n$_loreA',
        firstMessage: '$_loreB\n\nAnna looks up from her book.',
      ));

      final scan = scanInjectedFields(capture: after, probe: before);

      expect(scan.length, 2);
      expect(
        scan.fields,
        {InjectionField.scenario, InjectionField.firstMessage},
      );
      expect(scan.text, contains(_loreA));
      expect(scan.text, contains(_loreB));
    });

    test('reports nothing when the trigger fired nothing', () {
      final snapshot = PromptFields.fromPayload(payload());

      final scan = scanInjectedFields(capture: snapshot, probe: snapshot);

      expect(scan.isEmpty, isTrue);
      expect(scan.text, isEmpty);
    });

    // The server rewrites quotes, dashes and whitespace between one assembled
    // prompt and the next; that is drift, not an injection.
    test('drift in quotes, dashes and whitespace is not an injection', () {
      final before = PromptFields.fromPayload(
        payload(scenario: "You meet Anna at the library - it's quiet."),
      );
      final after = PromptFields.fromPayload(
        payload(scenario: 'You  meet Anna at the library — it’s quiet.'),
      );

      final scan = scanInjectedFields(capture: after, probe: before);

      expect(scan.isEmpty, isTrue);
    });

    test('a fragment shorter than the noise floor is dropped', () {
      final before = PromptFields.fromPayload(payload());
      final after = PromptFields.fromPayload(
        payload(scenario: 'You meet Anna at the library.\nIt rains.'),
      );

      final scan = scanInjectedFields(capture: after, probe: before);

      expect(scan.isEmpty, isTrue);
    });

    // A paragraph the separator already isolated from the tail of the prompt
    // must not come back a second time through the diff.
    test('text the separator already has is not reported again', () {
      final before = PromptFields.fromPayload(payload());
      final after = PromptFields.fromPayload(
        payload(scenario: 'You meet Anna at the library.\n$_loreA'),
      );

      final scan = scanInjectedFields(
        capture: after,
        probe: before,
        existing: 'Some other entry.\n\n$_loreA',
      );

      expect(scan.isEmpty, isTrue);
    });

    test('a public lorebook entry is not reported as closed material', () {
      final before = PromptFields.fromPayload(payload());
      final after = PromptFields.fromPayload(
        payload(scenario: 'You meet Anna at the library.\n$_loreA\n$_loreB'),
      );

      final scan = scanInjectedFields(
        capture: after,
        probe: before,
        publicContents: [_loreA],
      );

      expect(scan.length, 1);
      expect(scan.blocks.single.text, _loreB);
    });
  });

  group('always-on entries', () {
    // An entry that fires on the "." probe as well as on the trigger cancels out
    // of the first pass. The catalog's clean fields are the only baseline left.
    test('are recovered from the clean catalog fields', () {
      final probe = PromptFields.fromPayload(
        payload(scenario: 'You meet Anna at the library.\n$_loreA'),
      );

      final scan = scanInjectedFields(
        capture: probe,
        probe: probe,
        clean: PromptFields.fromMeta({
          'personality': 'Anna is a librarian.\nShe is thirty.',
          'scenario': 'You meet Anna at the library.',
          'example_dialogs': '<START>\nAnna: Hello.',
          'first_message': 'Anna looks up from her book.',
        }),
      );

      expect(scan.blocks.single.field, InjectionField.scenario);
      expect(scan.blocks.single.text, _loreA);
    });

    test('are reported once when both passes see them', () {
      final before = PromptFields.fromPayload(
        payload(scenario: 'You meet Anna at the library.\n$_loreA'),
      );
      final after = PromptFields.fromPayload(
        payload(scenario: 'You meet Anna at the library.\n$_loreA\n$_loreB'),
      );

      final scan = scanInjectedFields(
        capture: after,
        probe: before,
        clean: PromptFields.fromMeta({
          'personality': 'Anna is a librarian.\nShe is thirty.',
          'scenario': 'You meet Anna at the library.',
          'first_message': 'Anna looks up from her book.',
        }),
      );

      expect(scan.length, 2);
      expect(scan.text.split(_loreA).length - 1, 1);
    });

    // A closed card publishes no personality, and "" is not a baseline: read as
    // one it would report the whole card as injected lore.
    test('a withheld catalog field is not read as an empty baseline', () {
      final snapshot = PromptFields.fromPayload(payload());

      final scan = scanInjectedFields(
        capture: snapshot,
        probe: snapshot,
        clean: PromptFields.fromMeta({
          'personality': '',
          'scenario': '',
          'first_message': '',
        }),
      );

      expect(scan.isEmpty, isTrue);
    });

    test('every greeting counts as a baseline for the first message', () {
      final snapshot = PromptFields.fromPayload(
        payload(firstMessage: 'Anna waves from the reading room.'),
      );

      final scan = scanInjectedFields(
        capture: snapshot,
        probe: snapshot,
        clean: PromptFields.fromMeta({
          'personality': 'Anna is a librarian.\nShe is thirty.',
          'scenario': 'You meet Anna at the library.',
          'first_message': 'Anna looks up from her book.',
          'first_messages': ['Anna waves from the reading room.'],
        }),
      );

      expect(scan.isEmpty, isTrue);
    });
  });

  group('without a baseline', () {
    test('nothing is reported at all', () {
      final scan = scanInjectedFields(
        capture: PromptFields.fromPayload(
          payload(scenario: 'You meet Anna at the library.\n$_loreA'),
        ),
      );

      expect(scan.isEmpty, isTrue);
    });

    // With a clean definition but no probe, the capture is compared against the
    // catalog directly — one pass instead of two, but still exact.
    test('the clean catalog fields alone still find the lore', () {
      final scan = scanInjectedFields(
        capture: PromptFields.fromPayload(
          payload(scenario: 'You meet Anna at the library.\n$_loreA'),
        ),
        clean: PromptFields.fromMeta({
          'personality': 'Anna is a librarian.\nShe is thirty.',
          'scenario': 'You meet Anna at the library.',
          'example_dialogs': '<START>\nAnna: Hello.',
          'first_message': 'Anna looks up from her book.',
        }),
      );

      expect(scan.blocks.single.text, _loreA);
    });
  });

  group('withoutInjected', () {
    test('takes the recovered lore back out of its own field only', () {
      const scenario = 'You meet Anna at the library.\n$_loreA';
      final scan = scanInjectedFields(
        capture: PromptFields.fromPayload(payload(scenario: scenario)),
        probe: PromptFields.fromPayload(payload()),
      );

      expect(
        withoutInjected(scenario, InjectionField.scenario, scan),
        'You meet Anna at the library.',
      );
      expect(
        withoutInjected(scenario, InjectionField.persona, scan),
        scenario,
      );
    });

    test('an always-on entry recovered from the probe leaves the card', () {
      const persona = 'Anna is a librarian.\n$_loreA\nShe is thirty.';
      final probe = PromptFields.fromPayload(payload(persona: persona));
      final scan = scanInjectedFields(
        capture: probe,
        probe: probe,
        clean: PromptFields.fromMeta({
          'personality': 'Anna is a librarian.\nShe is thirty.',
        }),
      );

      expect(
        withoutInjected(persona, InjectionField.persona, scan),
        'Anna is a librarian.\nShe is thirty.',
      );
    });

    test('an empty scan leaves the text alone', () {
      expect(
        withoutInjected('Anna.\n\n\n\nBob.', InjectionField.persona,
            InjectionScan.none),
        'Anna.\n\n\n\nBob.',
      );
    });
  });

  group('PromptFields', () {
    test('reads the injectable fields out of a captured payload', () {
      final fields = PromptFields.fromPayload(payload());

      expect(fields.persona, 'Anna is a librarian.\nShe is thirty.');
      expect(fields.scenario, 'You meet Anna at the library.');
      expect(fields.example, '<START>\nAnna: Hello.');
      expect(fields.firstMessage, 'Anna looks up from her book.');
      expect(fields.isEmpty, isFalse);
    });

    test('applies the macro restoration as it reads', () {
      final fields = PromptFields.fromPayload(
        payload(persona: 'Anna is a librarian.'),
        restore: (t) => t.replaceAll('Anna', '{{char}}'),
      );

      expect(fields.persona, '{{char}} is a librarian.');
    });

    test('an absent metadata map is an empty baseline', () {
      expect(PromptFields.fromMeta(null).isEmpty, isTrue);
    });
  });
}
