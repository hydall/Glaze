import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_public_lorebook.dart';

/// A JanitorAI `scripts` metadata block: one public lorebook, one private.
Map<String, dynamic> _meta() => {
      'name': 'Aria',
      'scripts': [
        {'type': 'lorebook', 'id': 101, 'title': 'World Lore', 'is_public': true},
        {'type': 'lorebook', 'id': 202, 'title': 'Secret Lore', 'is_public': false},
        {'type': 'regex', 'id': 303, 'title': 'Not a lorebook'},
      ],
    };

/// Entries in JanitorAI's native script shape.
List<dynamic> _entries() => [
      {
        'key': ['Northern Keep', 'fortress'],
        'keysecondary': ['cliffs'],
        'content': 'The Northern Keep is an ancient fortress carved into the cliffs.',
        'insertion_order': 50,
        'constant': false,
      },
      {
        'keys': 'Frostfang, blade',
        'content': 'The Frostfang Blade never dulls.',
        'order': 100,
        'probability': 0.5,
      },
      {
        // Empty content → skipped.
        'key': ['ignored'],
        'content': '   ',
      },
    ];

void main() {
  group('lorebookScriptRefs', () {
    test('keeps only lorebook scripts and reads is_public', () {
      final refs = lorebookScriptRefs(_meta());
      expect(refs.length, 2);
      expect(refs[0].id, '101');
      expect(refs[0].title, 'World Lore');
      expect(refs[0].isPublic, true);
      expect(refs[1].id, '202');
      expect(refs[1].isPublic, false);
    });

    test('tolerates missing/!list scripts', () {
      expect(lorebookScriptRefs(null), isEmpty);
      expect(lorebookScriptRefs({'scripts': 'nope'}), isEmpty);
    });
  });

  group('parseScriptEntries', () {
    test('parses the stringified script array', () {
      final rec = {'script': jsonEncode(_entries())};
      expect(parseScriptEntries(rec).length, 3);
    });

    test('accepts an already-decoded array', () {
      expect(parseScriptEntries({'script': _entries()}).length, 3);
    });

    test('returns empty on garbage', () {
      expect(parseScriptEntries({'script': 'not json'}), isEmpty);
      expect(parseScriptEntries(null), isEmpty);
    });
  });

  group('convertJanitorScript', () {
    test('maps native entries to Glaze LorebookEntry, skipping empties', () {
      final book = convertJanitorScript(_entries(), name: 'World Lore');
      expect(book.name, 'World Lore');
      expect(book.activationScope, 'global');
      expect(book.entries.length, 2); // empty-content entry dropped

      final first = book.entries[0];
      expect(first.keys, ['Northern Keep', 'fortress']);
      expect(first.secondaryKeys, ['cliffs']);
      expect(first.order, 50);

      final second = book.entries[1];
      expect(second.keys, ['Frostfang', 'blade']); // comma string split
      // 0..1 fraction probability scaled to 0..100.
      expect(second.probability, 50);
    });

    test('scopes to a character when characterId is given', () {
      final book = convertJanitorScript(_entries(),
          name: 'World Lore', characterId: 'char-1');
      expect(book.activationScope, 'character');
      expect(book.activationTargetId, 'char-1');
    });
  });

  group('janitorScriptToTavernJson', () {
    test('emits a SillyTavern World Info book keyed by uid', () {
      final wi = janitorScriptToTavernJson(_entries(), name: 'World Lore');
      expect(wi['name'], 'World Lore');
      final entries = wi['entries'] as Map<String, dynamic>;
      expect(entries.length, 2);
      final e0 = entries['0'] as Map<String, dynamic>;
      expect(e0['uid'], 0);
      expect(e0['key'], ['Northern Keep', 'fortress']);
      expect(e0['comment'], isNotEmpty);
      // 0..1 probability scaled.
      final e1 = entries['1'] as Map<String, dynamic>;
      expect(e1['probability'], 50);
    });
  });
}
