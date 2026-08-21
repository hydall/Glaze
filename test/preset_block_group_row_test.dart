import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/preset_block_groups.dart';
import 'package:glaze_flutter/features/presets/widgets/preset_block_group_row.dart';

PresetBlock _block(String id, {bool enabled = true, String? folderId}) =>
    PresetBlock(
      id: id,
      name: id,
      role: 'system',
      content: 'content of $id',
      enabled: enabled,
      folderId: folderId,
    );

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: ListView(children: [child])),
);

void main() {
  const folder = PresetBlockFolder(id: 'f_styles', name: 'Narrative Styles');
  final blocks = [
    _block('roleplay', folderId: 'f_styles'),
    _block('ao3', enabled: false, folderId: 'f_styles'),
  ];

  Widget row({
    ValueChanged<bool>? onToggleFolder,
    VoidCallback? onRename,
    VoidCallback? onDelete,
    ValueChanged<PresetBlock>? onEdit,
    void Function(PresetBlock, bool)? onToggleBlock,
    ValueChanged<String>? onMoveBlockIn,
  }) => PresetBlockGroupRow(
    group: groupPresetBlocks(blocks, const [folder]).single,
    dragIndex: 0,
    isLast: true,
    onToggleFolder: onToggleFolder ?? (_) {},
    onRename: onRename ?? () {},
    onDelete: onDelete ?? () {},
    onEdit: onEdit ?? (_) {},
    onToggleBlock: onToggleBlock ?? (_, _) {},
    onMoveBlockIn: onMoveBlockIn ?? (_) {},
  );

  testWidgets('folds its blocks away and expands on tap', (tester) async {
    await tester.pumpWidget(_host(row()));

    expect(find.text('Narrative Styles'), findsOneWidget);
    expect(find.text('roleplay'), findsNothing);

    await tester.tap(find.text('Narrative Styles'));
    await tester.pumpAndSettle();

    expect(find.text('roleplay'), findsOneWidget);
    expect(find.text('ao3'), findsOneWidget);
  });

  testWidgets('the folder switch toggles the whole folder', (tester) async {
    bool? toggled;
    await tester.pumpWidget(_host(row(onToggleFolder: (v) => toggled = v)));

    // Collapsed, the folder's own switch is the only one on screen.
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(toggled, isFalse);
  });

  testWidgets('renames and deletes from the folder row', (tester) async {
    var renamed = false;
    var deleted = false;
    await tester.pumpWidget(
      _host(
        row(onRename: () => renamed = true, onDelete: () => deleted = true),
      ),
    );

    // Collapsed, the folder row owns the only pencil.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(renamed, isTrue);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });

  testWidgets('edits a block inside the folder', (tester) async {
    PresetBlock? edited;
    await tester.pumpWidget(_host(row(onEdit: (block) => edited = block)));

    await tester.tap(find.text('Narrative Styles'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    expect(edited?.id, 'ao3');
  });

  testWidgets('an empty folder says what to do with it', (tester) async {
    await tester.pumpWidget(
      _host(
        PresetBlockGroupRow(
          group: groupPresetBlocks(const [], const [folder]).single,
          dragIndex: null,
          isLast: true,
          onToggleFolder: (_) {},
          onRename: () {},
          onDelete: () {},
          onEdit: (_) {},
          onToggleBlock: (_, _) {},
          onMoveBlockIn: (_) {},
        ),
      ),
    );

    await tester.tap(find.text('Narrative Styles'));
    await tester.pumpAndSettle();
    expect(find.text('preset_folder_empty_blocks'), findsOneWidget);
  });
}
