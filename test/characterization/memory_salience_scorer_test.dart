import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_salience_scorer.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  group('MemorySalienceScorer (Phase G1)', () {
    test('death narrative flag produces isCore=true', () {
      final entry = MemoryEntry(
        id: 'm1',
        title: 'The death of Ren',
        content: 'Ren was killed in the battle at the old bridge.',
      );
      final salience = MemorySalienceScorer.score(entry, sessionId: 's1');
      expect(salience.narrativeFlags, contains('death'));
      expect(MemorySalienceScorer.isCore(salience), isTrue);
    });

    test('promise narrative flag produces isCore=true', () {
      final entry = MemoryEntry(
        id: 'm2',
        title: 'A promise made',
        content: 'Sable promised to protect the ritual map.',
      );
      final salience = MemorySalienceScorer.score(entry, sessionId: 's1');
      expect(salience.narrativeFlags, contains('promise'));
      expect(MemorySalienceScorer.isCore(salience), isTrue);
    });

    test('high emotional content (grief/betrayal) adds emotional component', () {
      final entry = MemoryEntry(
        id: 'm3',
        title: 'Betrayal at dawn',
        content: 'The grief of betrayal hung heavy. She felt the tension.',
      );
      final salience = MemorySalienceScorer.score(entry, sessionId: 's1');
      expect(salience.emotionalTags, contains('grief'));
      expect(salience.emotionalTags, contains('betrayal'));
      expect(salience.emotionalTags, contains('tension'));
      expect(salience.score, greaterThan(0.3));
    });

    test('low-importance mundane content has low salience', () {
      final entry = MemoryEntry(
        id: 'm4',
        title: 'Walked to the store',
        content: 'They walked to the store and bought bread.',
      );
      final salience = MemorySalienceScorer.score(entry, sessionId: 's1');
      expect(salience.score, lessThan(0.3));
      expect(MemorySalienceScorer.isCore(salience), isFalse);
    });

    test('importance field contributes to score', () {
      final lowImportance = MemoryEntry(
        id: 'm5',
        content: 'Some event happened here.',
        importance: 0.0,
      );
      final highImportance = MemoryEntry(
        id: 'm6',
        content: 'Some event happened here.',
        importance: 1.0,
      );
      final lowSal = MemorySalienceScorer.score(lowImportance, sessionId: 's1');
      final highSal = MemorySalienceScorer.score(
        highImportance,
        sessionId: 's1',
      );
      expect(highSal.score, greaterThan(lowSal.score));
    });

    test('score is clamped to [0, 1]', () {
      final entry = MemoryEntry(
        id: 'm7',
        title: 'Death promise confession battle',
        content:
            'He died after promising her. She confessed her betrayal in grief and tension. '
            'It was a battle that caused horror and dread. ${'word ' * 600}',
        importance: 1.0,
      );
      final salience = MemorySalienceScorer.score(entry, sessionId: 's1');
      expect(salience.score, lessThanOrEqualTo(1.0));
      expect(salience.score, greaterThanOrEqualTo(0.0));
    });

    test('hasDialogue and hasAction detected from content', () {
      final entry = MemoryEntry(
        id: 'm8',
        content: '"I will find them," she said, and walked toward the door.',
      );
      final salience = MemorySalienceScorer.score(entry, sessionId: 's1');
      expect(salience.hasDialogue, isTrue);
      expect(salience.hasAction, isTrue);
    });

    test('wordCount computed from content', () {
      final entry = MemoryEntry(
        id: 'm9',
        content: 'one two three four five',
      );
      final salience = MemorySalienceScorer.score(entry, sessionId: 's1');
      expect(salience.wordCount, 5);
    });
  });
}
