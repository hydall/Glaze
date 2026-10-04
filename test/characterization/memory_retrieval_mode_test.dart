import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_retrieval_mode.dart';

void main() {
  group('MemoryRetrievalMode capabilities', () {
    test('Balanced includes every Fast capability', () {
      expect(
        MemoryRetrievalMode.balanced.capabilities,
        containsAll(MemoryRetrievalMode.fast.capabilities),
      );
      expect(
        MemoryRetrievalMode.balanced.capabilities,
        contains(MemoryRetrievalCapability.catalogMatching),
      );
    });

    test('Deep includes every Balanced capability, including catalog', () {
      expect(
        MemoryRetrievalMode.deep.capabilities,
        containsAll(MemoryRetrievalMode.balanced.capabilities),
      );
      expect(
        MemoryRetrievalMode.deep.capabilities,
        contains(MemoryRetrievalCapability.catalogMatching),
      );
    });

    test('Legacy remains separate from the modern ladder', () {
      expect(MemoryRetrievalMode.legacy.isLegacy, isTrue);
      expect(MemoryRetrievalMode.legacy.capabilities, isEmpty);
      expect(
        MemoryRetrievalMode.legacy.supports(
          MemoryRetrievalCapability.modernSelector,
        ),
        isFalse,
      );
      expect(MemoryRetrievalMode.fast.isLegacy, isFalse);
    });

    test(
      'removed agentic value migrates to Deep without adding an LLM mode',
      () {
        expect(
          MemoryRetrievalMode.fromValue('agentic'),
          MemoryRetrievalMode.deep,
        );
        expect(
          MemoryRetrievalMode.fromValue('unknown'),
          MemoryRetrievalMode.fast,
        );
      },
    );
  });
}
