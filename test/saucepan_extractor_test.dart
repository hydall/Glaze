import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/saucepan_extractor.dart';

void main() {
  group('assembleFragments', () {
    // Golden vector minted from JAR's real saucepan.js proofs (Node): three real
    // fragments (shuffled), one decoy with a wrong proof, XOR-mask ordering.
    test('drops decoys, orders by key ^ mask, matches JAR byte-for-byte', () {
      final content = {
        'mask': 2654435769,
        'fragments': [
          {'key': 900, 'proof': 2300799767, 'text': '!'},
          {'key': 100, 'proof': 12345, 'text': 'XXXX'}, // decoy → dropped
          {'key': 500, 'proof': 2056336256, 'text': 'Hello, '},
          {'key': 100, 'proof': 1542016888, 'text': 'world'},
        ],
      };
      expect(assembleFragments(content), 'Hello, world!');
    });

    test('tolerates missing / malformed content', () {
      expect(assembleFragments(null), '');
      expect(assembleFragments(<String, dynamic>{}), '');
      expect(assembleFragments({'fragments': 'nope'}), '');
      expect(assembleFragments({'mask': 1, 'fragments': <dynamic>[]}), '');
    });

    test('a fragment with a wrong proof never survives', () {
      final content = {
        'mask': 2654435769,
        'fragments': [
          {'key': 500, 'proof': 2056336256, 'text': 'Hello, '},
          {'key': 100, 'proof': 999, 'text': 'world'}, // corrupted proof
        ],
      };
      expect(assembleFragments(content), 'Hello, ');
    });
  });

  group('parseCompanionId', () {
    test('extracts the id from a companion URL', () {
      expect(
        parseCompanionId('https://saucepan.ai/companion/abcdef01-2345-6789'),
        'abcdef01-2345-6789',
      );
      expect(
        parseCompanionId('http://www.saucepan.ai/companion/deadbeef1234'),
        'deadbeef1234',
      );
    });

    test('returns null for a non-companion URL', () {
      expect(parseCompanionId('https://janitorai.com/characters/x'), isNull);
      expect(parseCompanionId('nonsense'), isNull);
    });
  });
}
