import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_dedup_service.dart';
import 'package:glaze_flutter/core/llm/vector_math.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  group('cosineSimilarity', () {
    test('identical vectors return 1.0', () {
      final v = [1.0, 0.0, 0.0];
      expect(cosineSimilarity(v, v), closeTo(1.0, 1e-9));
    });

    test('orthogonal vectors return 0.0', () {
      expect(cosineSimilarity([1.0, 0.0], [0.0, 1.0]), closeTo(0.0, 1e-9));
    });

    test('empty vectors return 0.0', () {
      expect(cosineSimilarity([], []), 0.0);
    });

    test('different-length vectors return 0.0', () {
      expect(cosineSimilarity([1.0], [1.0, 2.0]), 0.0);
    });

    test('similar vectors return high score', () {
      final a = [1.0, 0.1, 0.0];
      final b = [1.0, 0.05, 0.0];
      final score = cosineSimilarity(a, b);
      expect(score, greaterThan(0.85));
    });
  });

  group('MemoryDedupResult', () {
    test('default values', () {
      const result = MemoryDedupResult();
      expect(result.status, 'ok');
      expect(result.candidatesChecked, 0);
      expect(result.pairsSentToLlm, 0);
      expect(result.merged, 0);
      expect(result.dropped, 0);
      expect(result.kept, 0);
      expect(result.totalElapsedMs, 0);
    });

    test('no_book status', () {
      const result = MemoryDedupResult(status: 'no_book');
      expect(result.status, 'no_book');
    });

    test('aborted status', () {
      const result = MemoryDedupResult(status: 'aborted');
      expect(result.status, 'aborted');
    });
  });

  group('MemoryEntry source filtering', () {
    test('studio_ledger source is separate from MemoryBook entries', () {
      final studio = MemoryEntry(
        id: 'mem_studio',
        title: 'Studio ledger',
        content: 'A durable fact',
        source: 'studio_ledger',
        kind: 'studio_ledger',
        status: 'active',
        createdAt: 0,
      );
      final curated = MemoryEntry(
        id: 'mem_curated',
        title: 'Manual',
        content: 'Manual entry',
        source: '',
        kind: 'curated',
        status: 'active',
        createdAt: 0,
      );

      expect(studio.source, 'studio_ledger');
      expect(curated.source, '');
      expect(studio.source != curated.source, true);
    });
  });

  group('DedupPairDecision', () {
    test('merge decision preserves fields', () {
      final decision = (
        entryAId: 'mem_a',
        entryBId: 'mem_b',
        action: 'merge',
        mergedContent: 'Combined content',
        mergedTitle: 'Combined title',
        mergedKeys: ['key1', 'key2'],
      );
      expect(decision.action, 'merge');
      expect(decision.mergedContent, 'Combined content');
      expect(decision.mergedTitle, 'Combined title');
      expect(decision.mergedKeys.length, 2);
    });

    test('drop decision has no merged fields', () {
      final decision = (
        entryAId: 'mem_a',
        entryBId: 'mem_b',
        action: 'drop',
        mergedContent: null,
        mergedTitle: null,
        mergedKeys: null,
      );
      expect(decision.action, 'drop');
      expect(decision.mergedContent, isNull);
    });

    test('keep decision has no merged fields', () {
      final decision = (
        entryAId: 'mem_a',
        entryBId: 'mem_b',
        action: 'keep',
        mergedContent: null,
        mergedTitle: null,
        mergedKeys: null,
      );
      expect(decision.action, 'keep');
    });
  });
}
