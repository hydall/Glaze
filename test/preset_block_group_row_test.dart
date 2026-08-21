import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/preset_block_groups.dart';
import 'package:glaze_flutter/features/presets/widgets/preset_block_group_row.dart';

PresetBlock _block(String id, {String? name, bool enabled = true}) =>
    PresetBlock(
      id: id,
      name: name ?? id,
      role: 'system',
      content: 'content of $id',
      enabled: enabled,
    );

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: ListView(children: [child])));

void main() {
  final blocks = [
    _block('style_header', name: '━ Narrative Styles'),
    _block('roleplay'),
    _block('ao3', enabled: false),
  ];

  Widget row({
    ValueChanged<bool>? onToggleFolder,
    VoidCallback? onDelete,
    ValueChanged<PresetBlock>? onEdit,
    void Function(PresetBlock, bool)? onToggleBlock,
    ValueChanged<String>? onMoveBlockIn,
  }) => PresetBlockGroupRow(
    group: groupPresetBlocks(blocks).single,
    dragIndex: 0,
    isLast: true,
    onToggleFolder: onToggleFolder ?? (_) {},
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
    // The header's own prompt stays editable as the folder's first row.
    expect(find.text('studio_group_header_prompt'), findsOneWidget);
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

  testWidgets('edits the header prompt and its blocks', (tester) async {
    PresetBlock? edited;
    await tester.pumpWidget(_host(row(onEdit: (block) => edited = block)));

    await tester.tap(find.text('Narrative Styles'));
    await tester.pumpAndSettle();

    // Rows in order: the header prompt, then the folder's blocks.
    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pumpAndSettle();
    expect(edited?.id, 'style_header');

    await tester.tap(find.byIcon(Icons.edit_outlined).last);
    await tester.pumpAndSettle();
    expect(edited?.id, 'ao3');
  });

  testWidgets('deletes the folder from its header row', (tester) async {
    var deleted = false;
    await tester.pumpWidget(_host(row(onDelete: () => deleted = true)));

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });
}
