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
    PresetBlockFolder kind = folder,
    ValueChanged<bool>? onToggleFolder,
    VoidCallback? onOptions,
    ValueChanged<PresetBlock>? onEdit,
    void Function(PresetBlock, bool)? onToggleBlock,
    ValueChanged<String>? onSelectBlock,
    ValueChanged<String>? onMoveBlockIn,
  }) => PresetBlockGroupRow(
    group: groupPresetBlocks(blocks, [kind]).single,
    dragIndex: 0,
    isLast: true,
    onToggleFolder: onToggleFolder ?? (_) {},
    onOptions: onOptions ?? () {},
    onEdit: onEdit ?? (_) {},
    onToggleBlock: onToggleBlock ?? (_, _) {},
    onSelectBlock: onSelectBlock ?? (_) {},
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

  testWidgets('opens the folder options', (tester) async {
    var opened = false;
    await tester.pumpWidget(_host(row(onOptions: () => opened = true)));

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  testWidgets('a checklist folder gives every block a switch', (tester) async {
    PresetBlock? toggled;
    await tester.pumpWidget(
      _host(row(onToggleBlock: (block, _) => toggled = block)),
    );

    await tester.tap(find.text('Narrative Styles'));
    await tester.pumpAndSettle();

    // The folder's own switch plus one per block.
    expect(find.byType(Switch), findsNWidgets(3));
    expect(find.byIcon(Icons.radio_button_off), findsNothing);

    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(toggled?.id, 'ao3');
  });

  testWidgets('a pick-one folder gives them radios instead', (tester) async {
    const pickOne = PresetBlockFolder(
      id: 'f_styles',
      name: 'Narrative Styles',
      exclusive: true,
    );
    String? picked;
    await tester.pumpWidget(
      _host(row(kind: pickOne, onSelectBlock: (id) => picked = id)),
    );

    // Collapsed, the subtitle names the pick instead of counting.
    expect(find.text('roleplay'), findsOneWidget);
    expect(find.text('studio_badge_pick_one'), findsOneWidget);

    await tester.tap(find.text('Narrative Styles'));
    await tester.pumpAndSettle();

    // Only the folder keeps a switch; the blocks are radios.
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byIcon(Icons.radio_button_off));
    await tester.pumpAndSettle();
    expect(picked, 'ao3');
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
          onOptions: () {},
          onEdit: (_) {},
          onToggleBlock: (_, _) {},
          onSelectBlock: (_) {},
          onMoveBlockIn: (_) {},
        ),
      ),
    );

    await tester.tap(find.text('Narrative Styles'));
    await tester.pumpAndSettle();
    expect(find.text('preset_folder_empty_blocks'), findsOneWidget);
  });
}
