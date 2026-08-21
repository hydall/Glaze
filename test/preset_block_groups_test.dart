import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/preset_block_groups.dart';

PresetBlock _block(
  String id, {
  String? name,
  bool enabled = true,
  bool isStashed = false,
}) => PresetBlock(
  id: id,
  name: name ?? id,
  role: 'system',
  content: 'content of $id',
  enabled: enabled,
  isStashed: isStashed,
);

List<String> _ids(List<PresetBlock> blocks) =>
    blocks.map((block) => block.id).toList();

void main() {
  final blocks = [
    _block('intro'),
    _block('style_header', name: '━✏️ Narrative Styles'),
    _block('roleplay'),
    _block('ao3', enabled: false),
    _block('pov_header', name: '━ Point-of-View'),
    _block('third_person'),
    _block('chat_history'),
  ];

  group('groupPresetBlocks', () {
    test('opens a folder at every ━ header and owns the blocks below it', () {
      final rows = groupPresetBlocks(blocks);

      expect(rows, hasLength(3));
      expect(rows[0].isFolder, isFalse);
      expect(rows[0].standalone!.id, 'intro');
      expect(rows[1].header!.id, 'style_header');
      expect(_ids(rows[1].children), ['roleplay', 'ao3']);
      expect(rows[2].header!.id, 'pov_header');
      expect(_ids(rows[2].children), ['third_person', 'chat_history']);
    });

    test('flattening rows reproduces the block order', () {
      expect(
        _ids(flattenPresetBlockGroups(groupPresetBlocks(blocks))),
        _ids(blocks),
      );
    });

    test('strips the header ornament for display', () {
      expect(presetGroupTitle(blocks[1]), 'Narrative Styles');
      expect(presetGroupHeaderName('  Styles '), '━ Styles');
    });

    test('a stashed block never opens a folder', () {
      final rows = groupPresetBlocks([
        _block('archived_header', name: '━ Archived', isStashed: true),
        _block('intro'),
      ]);

      expect(rows.every((row) => !row.isFolder), isTrue);
      expect(rows, hasLength(2));
    });

    test('finds the folder a block sits in', () {
      expect(findPresetGroupForBlock(blocks, 'ao3')?.header?.id, 'style_header');
      expect(findPresetGroupForBlock(blocks, 'intro'), isNull);
      expect(findPresetGroupForBlock(blocks, 'style_header'), isNull);
    });
  });

  group('applyPresetFolderEnablement', () {
    test('a disabled folder takes its blocks out of the prompt', () {
      final rows = groupPresetBlocks(blocks);
      final disabled = togglePresetBlockGroup(blocks, rows[1], false);

      final resolved = applyPresetFolderEnablement(disabled);
      Map<String, bool> enabledById(List<PresetBlock> list) => {
        for (final block in list) block.id: block.enabled,
      };

      expect(enabledById(resolved), {
        'intro': true,
        'style_header': false,
        'roleplay': false,
        'ao3': false,
        'pov_header': true,
        'third_person': true,
        'chat_history': true,
      });
      // Only the header is written — re-enabling the folder restores the
      // children's own switches.
      expect(enabledById(disabled)['roleplay'], isTrue);
      expect(enabledById(disabled)['ao3'], isFalse);
    });

    test('leaves an enabled folder and stashed blocks untouched', () {
      final stashed = [..._blocksWithStash()];
      final resolved = applyPresetFolderEnablement(stashed);
      expect(_ids(resolved), _ids(stashed));
      expect(resolved.map((b) => b.enabled), stashed.map((b) => b.enabled));
    });
  });

  group('folder edits', () {
    test('moves a block into a folder, after its last block', () {
      final moved = movePresetBlockIntoGroup(
        blocks: blocks,
        blockId: 'intro',
        target: groupPresetBlocks(blocks)[1],
      );

      expect(_ids(moved), [
        'style_header',
        'roleplay',
        'ao3',
        'intro',
        'pov_header',
        'third_person',
        'chat_history',
      ]);
    });

    test('never nests a folder or re-adds a block already inside', () {
      final rows = groupPresetBlocks(blocks);
      expect(
        movePresetBlockIntoGroup(
          blocks: blocks,
          blockId: 'pov_header',
          target: rows[1],
        ),
        same(blocks),
      );
      expect(
        movePresetBlockIntoGroup(
          blocks: blocks,
          blockId: 'ao3',
          target: rows[1],
        ),
        same(blocks),
      );
    });

    test('moves a block out of its folder to the end of the list', () {
      final moved = movePresetBlockOutOfGroups(
        blocks: blocks,
        blockId: 'roleplay',
      );

      expect(_ids(moved), [
        'intro',
        'style_header',
        'ao3',
        'pov_header',
        'third_person',
        'chat_history',
        'roleplay',
      ]);
      // A block that is not in a folder stays where it is.
      expect(
        movePresetBlockOutOfGroups(blocks: blocks, blockId: 'intro'),
        same(blocks),
      );
    });

    test('deleting a folder keeps its blocks', () {
      final dissolved = dissolvePresetBlockGroup(
        blocks: blocks,
        group: groupPresetBlocks(blocks)[1],
      );

      expect(_ids(dissolved), [
        'intro',
        'roleplay',
        'ao3',
        'pov_header',
        'third_person',
        'chat_history',
      ]);
      expect(groupPresetBlocks(dissolved).first.isFolder, isFalse);
    });

    test('reordering rows moves a folder with everything in it', () {
      final rows = groupPresetBlocks(blocks);
      final reordered = [...rows];
      reordered.insert(0, reordered.removeAt(2));

      expect(_ids(flattenPresetBlockGroups(reordered)), [
        'pov_header',
        'third_person',
        'chat_history',
        'intro',
        'style_header',
        'roleplay',
        'ao3',
      ]);
    });
  });
}

List<PresetBlock> _blocksWithStash() => [
  _block('intro'),
  _block('style_header', name: '━ Styles'),
  _block('roleplay', enabled: false),
  _block('archived', isStashed: true, enabled: true),
];
