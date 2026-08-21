import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/preset_block_groups.dart';

PresetBlock _block(
  String id, {
  bool enabled = true,
  bool isStashed = false,
  String? folderId,
}) => PresetBlock(
  id: id,
  name: id,
  role: 'system',
  content: 'content of $id',
  enabled: enabled,
  isStashed: isStashed,
  folderId: folderId,
);

List<String> _ids(List<PresetBlock> blocks) =>
    blocks.map((block) => block.id).toList();

void main() {
  const styles = PresetBlockFolder(id: 'f_styles', name: 'Narrative Styles');
  const pov = PresetBlockFolder(id: 'f_pov', name: 'Point-of-View');
  const folders = [styles, pov];

  final blocks = [
    _block('intro'),
    _block('roleplay', folderId: 'f_styles'),
    _block('ao3', enabled: false, folderId: 'f_styles'),
    _block('third_person', folderId: 'f_pov'),
    _block('chat_history'),
  ];

  group('groupPresetBlocks', () {
    test('draws a folder at its first block and gives it every member', () {
      final rows = groupPresetBlocks(blocks, folders);

      expect(rows, hasLength(4));
      expect(rows[0].isFolder, isFalse);
      expect(rows[0].standalone!.id, 'intro');
      expect(rows[1].folder!.id, 'f_styles');
      expect(_ids(rows[1].children), ['roleplay', 'ao3']);
      expect(rows[2].folder!.id, 'f_pov');
      expect(_ids(rows[2].children), ['third_person']);
      expect(rows[3].standalone!.id, 'chat_history');
    });

    test('never infers a folder from a block name', () {
      final rows = groupPresetBlocks([
        PresetBlock(
          id: 'divider',
          name: '━✏️ Narrative Styles',
          role: 'system',
          content: '',
        ),
        _block('roleplay'),
      ], const []);

      expect(rows.every((row) => !row.isFolder), isTrue);
      expect(rows, hasLength(2));
    });

    test('a block naming an undeclared folder stays top-level', () {
      final rows = groupPresetBlocks([
        _block('orphan', folderId: 'gone'),
      ], folders);

      expect(rows.first.isFolder, isFalse);
      expect(rows.first.standalone!.id, 'orphan');
      // The declared folders are still drawn, empty.
      expect(rows.skip(1).every((row) => row.children.isEmpty), isTrue);
    });

    test('a folder with no blocks is drawn after the block rows', () {
      final rows = groupPresetBlocks([_block('intro')], folders);

      expect(rows, hasLength(3));
      expect(rows[0].standalone!.id, 'intro');
      expect(rows[1].folder!.id, 'f_styles');
      expect(rows[1].children, isEmpty);
      expect(rows[2].folder!.id, 'f_pov');
    });

    test('collects members a hand-written JSON interleaved', () {
      final rows = groupPresetBlocks([
        _block('roleplay', folderId: 'f_styles'),
        _block('intro'),
        _block('ao3', folderId: 'f_styles'),
      ], folders);

      expect(_ids(rows[0].children), ['roleplay', 'ao3']);
      expect(rows[1].standalone!.id, 'intro');
      // Flattening a folder's members makes them contiguous.
      expect(_ids(flattenPresetBlockGroups(rows)), [
        'roleplay',
        'ao3',
        'intro',
      ]);
    });

    test('flattening rows reproduces an already-grouped block order', () {
      expect(
        _ids(flattenPresetBlockGroups(groupPresetBlocks(blocks, folders))),
        _ids(blocks),
      );
    });

    test('finds the folder a block belongs to', () {
      expect(findPresetFolderForBlock(blocks, folders, 'ao3')?.id, 'f_styles');
      expect(findPresetFolderForBlock(blocks, folders, 'intro'), isNull);
    });
  });

  group('applyPresetFolderEnablement', () {
    test('a disabled folder takes its blocks out of the prompt', () {
      final disabled = togglePresetBlockFolder(folders, 'f_styles', false);
      final resolved = applyPresetFolderEnablement(blocks, disabled);

      expect(
        {for (final b in resolved) b.id: b.enabled},
        {
          'intro': true,
          'roleplay': false,
          'ao3': false,
          'third_person': true,
          'chat_history': true,
        },
      );
      // The blocks' own switches are untouched, so re-enabling the folder
      // restores the selection.
      expect({for (final b in blocks) b.id: b.enabled}['roleplay'], isTrue);
    });

    test('leaves everything alone when no folder is disabled', () {
      expect(applyPresetFolderEnablement(blocks, folders), same(blocks));
    });

    test('resolves through the preset', () {
      final preset = Preset(
        id: 'p',
        name: 'p',
        blocks: blocks,
        blockFolders: togglePresetBlockFolder(folders, 'f_pov', false),
      );

      final resolved = resolvePresetFolders(preset);
      expect(resolved.blocks.where((b) => b.enabled).map((b) => b.id), [
        'intro',
        'roleplay',
        'chat_history',
      ]);
    });
  });

  group('folder edits', () {
    test('moves a block into a folder, after its last member', () {
      final moved = movePresetBlockIntoFolder(
        blocks: blocks,
        blockId: 'intro',
        folderId: 'f_styles',
      );

      expect(_ids(moved), [
        'roleplay',
        'ao3',
        'intro',
        'third_person',
        'chat_history',
      ]);
      expect(moved[2].folderId, 'f_styles');
    });

    test('moves a block into an empty folder at the end of the list', () {
      final moved = movePresetBlockIntoFolder(
        blocks: blocks,
        blockId: 'intro',
        folderId: 'f_empty',
      );

      expect(_ids(moved).last, 'intro');
      expect(moved.last.folderId, 'f_empty');
    });

    test('moving a block into the folder it is already in changes nothing', () {
      expect(
        movePresetBlockIntoFolder(
          blocks: blocks,
          blockId: 'ao3',
          folderId: 'f_styles',
        ),
        same(blocks),
      );
    });

    test('takes a block out of its folder, in place', () {
      final moved = movePresetBlockOutOfFolder(
        blocks: blocks,
        blockId: 'roleplay',
      );

      expect(_ids(moved), _ids(blocks));
      expect(moved[1].folderId, isNull);
      expect(
        movePresetBlockOutOfFolder(blocks: blocks, blockId: 'intro'),
        same(blocks),
      );
    });

    test('deleting a folder keeps its blocks', () {
      final cleared = clearPresetFolderMembership(blocks, 'f_styles');

      expect(_ids(cleared), _ids(blocks));
      expect(cleared.where((b) => b.folderId == 'f_styles'), isEmpty);
      expect(cleared[3].folderId, 'f_pov');
    });

    test('renames a folder', () {
      expect(
        renamePresetBlockFolder(folders, 'f_pov', '  Camera  ').last.name,
        'Camera',
      );
    });

    test('reordering rows moves a folder with everything in it', () {
      final rows = groupPresetBlocks(blocks, folders);
      final reordered = [...rows];
      reordered.insert(0, reordered.removeAt(2));

      expect(_ids(flattenPresetBlockGroups(reordered)), [
        'third_person',
        'intro',
        'roleplay',
        'ao3',
        'chat_history',
      ]);
    });
  });
}
