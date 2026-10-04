import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_groups.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_reorder.dart';

StudioPresetBlock _block(
  String id, {
  int order = 0,
  String title = '',
  String injectionPoint = 'pregen',
}) {
  return StudioPresetBlock(
    id: id,
    title: title.isEmpty ? id : title,
    order: order,
    injectionPoint: injectionPoint,
  );
}

/// Places [entries] in the given section, mirroring what the section list
/// reports after a drag.
List<StudioPresetRowPlacement> _rows(
  List<StudioPresetBlockGroup> entries, {
  String at = 'pregen',
}) {
  return [
    for (final entry in entries)
      StudioPresetRowPlacement(entry: entry, injectionPoint: at),
  ];
}

List<String> _idsInOrder(List<StudioPresetBlock> blocks) {
  final sorted = [...blocks]..sort((a, b) => a.order.compareTo(b.order));
  return sorted.map((b) => b.id).toList();
}

void main() {
  group('reorderStudioPresetBlocks', () {
    test('permutes the visible rows and renumbers order densely', () {
      final blocks = [
        _block('a', order: 0),
        _block('b', order: 1),
        _block('c', order: 2),
      ];
      final entries = groupStudioPresetBlocks(blocks);
      expect(entries.length, 3);

      // Drag the last row to the top.
      final result = reorderStudioPresetBlocks(
        all: blocks,
        rows: _rows([entries[2], entries[0], entries[1]]),
      );

      expect(_idsInOrder(result), ['c', 'a', 'b']);
      expect(result.map((b) => b.order).toList()..sort(), [0, 1, 2]);
    });

    test('re-targets a row dropped under another section header', () {
      final blocks = [
        _block('pre1', order: 0),
        _block('pre2', order: 1),
        _block('fin1', order: 2, injectionPoint: 'final'),
      ];
      final entries = groupStudioPresetBlocks(blocks);
      // pre2 lands in the Final section; the others stay put.
      final result = reorderStudioPresetBlocks(
        all: blocks,
        rows: [
          StudioPresetRowPlacement(entry: entries[0], injectionPoint: 'pregen'),
          StudioPresetRowPlacement(entry: entries[2], injectionPoint: 'final'),
          StudioPresetRowPlacement(entry: entries[1], injectionPoint: 'final'),
        ],
      );

      final byId = {for (final b in result) b.id: b};
      expect(byId['pre1']!.injectionPoint, 'pregen');
      expect(byId['pre2']!.injectionPoint, 'final');
      expect(byId['fin1']!.injectionPoint, 'final');
      expect(_idsInOrder(result), ['pre1', 'fin1', 'pre2']);
    });

    test('leaves blocks no row claims in their slots', () {
      final blocks = [
        _block('pre1', order: 0),
        _block('orphan', order: 1),
        _block('pre2', order: 2),
      ];
      // Only the two `pre` rows are handed in; `orphan` is not surfaced by any
      // row and must keep the middle slot.
      final result = reorderStudioPresetBlocks(
        all: blocks,
        rows: _rows([
          StudioPresetBlockGroup.standalone(blocks[2]),
          StudioPresetBlockGroup.standalone(blocks[0]),
        ]),
      );

      expect(_idsInOrder(result), ['pre2', 'orphan', 'pre1']);
    });

    test('moves and re-targets a section header with its children', () {
      final blocks = [
        _block('lead', order: 0),
        _block('head', order: 1, title: '━ Narrative'),
        _block('child1', order: 2),
        _block('child2', order: 3),
      ];
      final entries = groupStudioPresetBlocks(blocks);
      // One standalone row, then a section (header + 2 children).
      expect(entries.length, 2);
      expect(entries.first.standalone?.id, 'lead');
      expect(entries.last.header?.id, 'head');

      final result = reorderStudioPresetBlocks(
        all: blocks,
        rows: [
          StudioPresetRowPlacement(
            entry: entries.last,
            injectionPoint: 'cleaner',
          ),
          StudioPresetRowPlacement(
            entry: entries.first,
            injectionPoint: 'pregen',
          ),
        ],
      );

      expect(_idsInOrder(result), ['head', 'child1', 'child2', 'lead']);
      for (final id in ['head', 'child1', 'child2']) {
        expect(
          result.firstWhere((b) => b.id == id).injectionPoint,
          'cleaner',
          reason: '$id should follow its section',
        );
      }
      expect(result.firstWhere((b) => b.id == 'lead').injectionPoint, 'pregen');
    });

    test('skips the synthesized Tense header instead of bailing out', () {
      final blocks = [
        _block('pov', order: 0, title: '━ Point-of-View'),
        _block('pov_first', order: 1, title: 'First person'),
        _block('tense_past', order: 2, title: 'Tense modifier: past'),
      ];
      final entries = groupStudioPresetBlocks(blocks);
      // The grouper splits the tense modifier into its own section under a
      // header block that exists only in the UI.
      expect(entries.length, 2);
      expect(entries.last.header?.id, 'tense_past_group');

      final result = reorderStudioPresetBlocks(
        all: blocks,
        rows: _rows([entries.last, entries.first]),
      );

      expect(_idsInOrder(result), ['tense_past', 'pov', 'pov_first']);
      expect(result.any((b) => b.id == 'tense_past_group'), isFalse);
    });

    test('is a no-op when a block is claimed by two rows', () {
      final duplicated = _block('a', order: 0);
      final blocks = [duplicated, _block('b', order: 1)];
      final result = reorderStudioPresetBlocks(
        all: blocks,
        rows: _rows([
          StudioPresetBlockGroup.standalone(duplicated),
          StudioPresetBlockGroup.standalone(duplicated),
        ]),
      );
      expect(identical(result, blocks), isTrue);
    });
  });

  group('studioPresetEntryBlocks', () {
    test('returns the standalone block for an ungrouped row', () {
      final block = _block('solo');
      final entry = StudioPresetBlockGroup.standalone(block);
      expect(studioPresetEntryBlocks(entry).map((b) => b.id), ['solo']);
    });

    test('emits boundaries around the header and children', () {
      final entry = StudioPresetBlockGroup.section(
        header: _block('head', title: '━ Section'),
        openingBoundary: _block('head_group_open'),
        closingBoundary: _block('head_group_close'),
        children: [_block('child')],
        exclusive: false,
      );
      expect(studioPresetEntryBlocks(entry).map((b) => b.id).toList(), [
        'head_group_open',
        'head',
        'child',
        'head_group_close',
      ]);
    });
  });

  group('folder block movement', () {
    test(
      'moves a standalone block into a folder before its closing boundary',
      () {
        final blocks = [
          _block('header', title: '━ Folder', order: 0),
          _block('child', order: 1),
          _block('header_group_close', order: 2),
          _block('standalone', order: 3, injectionPoint: 'final'),
        ];
        blocks[2] = blocks[2].copyWith(groupBoundary: 'close');
        final group = groupStudioPresetBlocks(blocks).first;

        final result = moveStudioPresetBlockToGroup(
          all: blocks,
          blockId: 'standalone',
          targetGroup: group,
        );

        expect(_idsInOrder(result), [
          'header',
          'child',
          'standalone',
          'header_group_close',
        ]);
        expect(
          result.firstWhere((block) => block.id == 'standalone').injectionPoint,
          'pregen',
        );
      },
    );

    test('moves a child out to an injection point as a standalone block', () {
      final blocks = [
        _block('header', title: '━ Folder', order: 0),
        _block('child', order: 1),
        _block('header_group_close', order: 2),
      ];
      blocks[2] = blocks[2].copyWith(groupBoundary: 'close');

      final result = moveStudioPresetBlockToSection(
        all: blocks,
        blockId: 'child',
        injectionPoint: 'final',
      );

      expect(_idsInOrder(result), ['header', 'header_group_close', 'child']);
      expect(groupStudioPresetBlocks(result).last.standalone?.id, 'child');
    });

    test('dissolves a folder without deleting its children', () {
      final blocks = [
        _block('open', order: 0),
        _block('header', title: '━ Folder', order: 1),
        _block('child', order: 2),
        _block('close', order: 3),
      ];
      blocks[0] = blocks[0].copyWith(
        id: 'header_group_open',
        groupBoundary: 'open',
      );
      blocks[3] = blocks[3].copyWith(
        id: 'header_group_close',
        groupBoundary: 'close',
      );
      final group = groupStudioPresetBlocks(blocks).single;

      final result = dissolveStudioPresetBlockGroup(all: blocks, group: group);

      expect(_idsInOrder(result), ['child']);
      expect(groupStudioPresetBlocks(result).single.standalone?.id, 'child');
    });
  });
}
