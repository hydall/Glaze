import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_entity_extractor.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  group('MemoryEntityExtractor (Phase G3)', () {
    test('extracts characters from known names', () {
      final entry = MemoryEntry(
        id: 'm1',
        title: 'Meeting at the bridge',
        content: 'Ren accused Sable of hiding the map. Sable said nothing.',
      );
      final entities = MemoryEntityExtractor.extract(
        entry,
        sessionId: 's1',
        knownCharacterNames: ['Ren', 'Sable'],
      );
      final chars = entities.where((e) => e.entityType == 'character').toList();
      expect(chars.any((e) => e.name == 'Ren'), isTrue);
      expect(chars.any((e) => e.name == 'Sable'), isTrue);
    });

    test('extracts characters by verb adjacency', () {
      final entry = MemoryEntry(
        id: 'm2',
        content: 'Melina walked to the door. Pulchra nodded.',
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      final chars = entities.where((e) => e.entityType == 'character').toList();
      expect(chars.any((e) => e.name == 'Melina'), isTrue);
      expect(chars.any((e) => e.name == 'Pulchra'), isTrue);
    });

    test('extracts characters by possessive', () {
      final entry = MemoryEntry(
        id: 'm3',
        content: "Sable's eyes narrowed at the suggestion.",
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      expect(entities.any((e) => e.name == 'Sable'), isTrue);
    });

    test('extracts characters by quote attribution', () {
      final entry = MemoryEntry(id: 'm4', content: '"I will not," said Ren.');
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      expect(entities.any((e) => e.name == 'Ren'), isTrue);
    });

    test('extracts locations by suffix', () {
      final entry = MemoryEntry(
        id: 'm5',
        title: 'Old Bridge',
        content: 'They met at the old Stone Bridge at dusk.',
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      final locations = entities
          .where((e) => e.entityType == 'location')
          .toList();
      expect(locations.any((e) => e.name.contains('Bridge')), isTrue);
    });

    test('extracts locations by locative phrase', () {
      final entry = MemoryEntry(
        id: 'm6',
        content: 'They arrived at Crantmere and looked around.',
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      expect(
        entities.any(
          (e) => e.entityType == 'location' && e.name == 'Crantmere',
        ),
        isTrue,
      );
    });

    test('honorific strip creates alias', () {
      final entry = MemoryEntry(
        id: 'm7',
        content: 'Captain Melina ordered the retreat.',
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      final melina = entities.firstWhere(
        (e) => e.name == 'Melina',
        orElse: () => throw StateError('Melina not found'),
      );
      expect(melina.aliases, contains('Captain Melina'));
    });

    test('first name alias for multi-word names', () {
      final entry = MemoryEntry(
        id: 'm8',
        content: 'Pulchra Fellini entered the room.',
        keys: const [],
      );
      final entities = MemoryEntityExtractor.extract(
        entry,
        sessionId: 's1',
        knownCharacterNames: ['Pulchra Fellini'],
      );
      final pulchra = entities.firstWhere((e) => e.name == 'Pulchra Fellini');
      expect(pulchra.aliases, contains('Pulchra'));
    });

    test('proper nouns appearing 2+ times are extracted', () {
      final entry = MemoryEntry(
        id: 'm9',
        content: 'Varo watched. Varo waited. Then Varo struck.',
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      expect(entities.any((e) => e.name == 'Varo'), isTrue);
    });

    test('honorifics are not treated as character names', () {
      final entry = MemoryEntry(
        id: 'm10',
        content: 'The Lord declared war. The Lady agreed.',
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');
      expect(entities.any((e) => e.name == 'Lord'), isFalse);
      expect(entities.any((e) => e.name == 'Lady'), isFalse);
    });

    test('does not extract sentence-start common words as characters', () {
      final entry = MemoryEntry(
        id: 'm11',
        title: 'Militech buys evidence from David apartment',
        content:
            "Militech bought David Martinez's door lock optical module. "
            "Digital trail matches cipher Lucy extracted from Beastie's systems. "
            "Militech reconstructing attacker profiles from Arasaka Tower. "
            "Storm group may enter David's apartment within hours. "
            "Reported Lucy's shadow auction beacon tripped her subnet. "
            "Call ended immediately after intel delivery.",
      );
      final entities = MemoryEntityExtractor.extract(entry, sessionId: 's1');

      final names = entities.map((e) => e.name).toSet();
      expect(names, containsAll(['Militech', 'Lucy']));
      expect(names, isNot(contains('Digital')));
      expect(names, isNot(contains('Reported')));
      expect(names, isNot(contains('Call')));
      expect(names, isNot(contains('Storm')));
      expect(
        names,
        isNot(
          contains(
            'Militech reconstructing attacker profiles from Arasaka Tower',
          ),
        ),
      );
    });
  });
}
