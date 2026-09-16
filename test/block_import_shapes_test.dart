import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/services/block_transfer_service.dart';
import 'package:glaze_flutter/features/extensions/services/upstream_block_codec.dart';

/// A block of ours as it actually appears in a file.
///
/// `toJson` alone leaves nested objects as live instances — they only become
/// JSON once encoded — so an import test has to go through real text, the same
/// way a picked file does.
Map<String, dynamic> ownBlockAsFile(String name) =>
    jsonDecode(jsonEncode(BlockConfig(id: 'own-$name', name: name)))
        as Map<String, dynamic>;

Map<String, dynamic> upstreamBlock(String name) => {
  'id': 'id-$name',
  'name': name,
  'block_type': 'generated',
  'disabled': false,
  'user_message': false,
  'char_message': true,
  'prompt': 'p',
  'context': const <Map<String, dynamic>>[],
};

void main() {
  group('blocksFromJson', () {
    test('reads a single block from the original extension', () {
      final blocks = blocksFromJson(upstreamBlock('solo'));
      expect(blocks.map((b) => b.name), ['solo']);
    });

    test('reads a bare array of blocks', () {
      final blocks = blocksFromJson([upstreamBlock('a'), upstreamBlock('b')]);
      expect(blocks.map((b) => b.name), ['a', 'b']);
    });

    test('reads a set exported by the original extension', () {
      final blocks = blocksFromJson({
        'name': 'My set',
        'global_blocks': [upstreamBlock('a'), upstreamBlock('b')],
      });
      expect(blocks.map((b) => b.name), ['a', 'b']);
    });

    test('reads one of our own presets', () {
      final blocks = blocksFromJson({
        'id': 'p1',
        'name': 'ours',
        'blocks': [ownBlockAsFile('mine')],
      });
      expect(blocks.map((b) => b.name), ['mine']);
    });

    test('reads a file mixing both formats', () {
      final blocks = blocksFromJson([
        upstreamBlock('theirs'),
        ownBlockAsFile('mine'),
      ]);
      expect(blocks.map((b) => b.name), ['theirs', 'mine']);
    });

    test('numbers blocks from the requested starting order', () {
      final blocks = blocksFromJson([
        upstreamBlock('a'),
        upstreamBlock('b'),
      ], startOrder: 5);
      expect(blocks.map((b) => b.order), [5, 6]);
    });

    test('skips entries that are neither shape instead of failing the file', () {
      final blocks = blocksFromJson([
        upstreamBlock('good'),
        'nonsense',
        {'totally': 'unrelated'},
      ]);
      expect(blocks.map((b) => b.name), contains('good'));
    });

    test('returns nothing for a document that holds no blocks', () {
      expect(blocksFromJson('just a string'), isEmpty);
      expect(blocksFromJson(42), isEmpty);
    });

    test('survives a real export decoded straight from text', () {
      final text = jsonEncode(upstreamBlock('from-text'));
      final blocks = blocksFromJson(jsonDecode(text));
      expect(blocks, hasLength(1));
      expect(blocks.single.triggerOnChar, isTrue);
      // Re-exporting keeps it readable by the original extension.
      expect(encodeUpstreamBlock(blocks.single)['block_type'], 'generated');
    });
  });
}
