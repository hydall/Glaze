import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_groups.dart';
import 'package:glaze_flutter/features/studio/widgets/studio_block_row.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: ListView(children: [child])),
);

void main() {
  testWidgets('exclusive group expands and selects one option', (tester) async {
    const blocks = [
      StudioPresetBlock(
        id: 'pov_header_group_open',
        title: 'Opening tag',
        content: '<loompov>',
        order: 0,
      ),
      StudioPresetBlock(
        id: 'pov_header',
        title: '━🧍 Point-of-View',
        content: 'POV header instructions',
        order: 1,
      ),
      StudioPresetBlock(
        id: 'third_person',
        title: 'Third Person Narrator',
        enabled: true,
        order: 2,
      ),
      StudioPresetBlock(
        id: 'second_person',
        title: 'Second Person',
        enabled: false,
        order: 3,
      ),
      StudioPresetBlock(
        id: 'pov_header_group_close',
        title: 'Closing tag',
        content: '</loompov>',
        order: 4,
      ),
    ];
    final group = groupStudioPresetBlocks(blocks).single;
    String? selected;
    StudioPresetBlock? edited;

    await tester.pumpWidget(
      _host(
        StudioBlockGroupRow(
          group: group,
          dragIndex: 0,
          isLast: true,
          onSelectExclusive: (id) => selected = id,
          onToggle: (_, _) {},
          onEdit: (block) => edited = block,
          onDelete: (_) {},
          onDeleteGroup: (_) {},
          onMoveBlock: (_, _) {},
          onToggleGroup: (_) {},
        ),
      ),
    );

    // Collapsed: only the header row and the currently selected child's name
    // (as the row subtitle) are visible.
    expect(find.text('Point-of-View'), findsOneWidget);
    expect(find.text('Second Person'), findsNothing);

    await tester.tap(find.text('Point-of-View'));
    await tester.pumpAndSettle();

    expect(find.text('Second Person'), findsOneWidget);
    expect(find.text('Opening tag'), findsOneWidget);
    expect(find.text('studio_group_header_prompt'), findsOneWidget);
    expect(find.text('Closing tag'), findsOneWidget);

    await tester.tap(find.text('Opening tag'));
    await tester.pumpAndSettle();
    expect(edited?.id, 'pov_header_group_open');

    await tester.tap(find.text('studio_group_header_prompt'));
    await tester.pumpAndSettle();
    expect(edited?.id, 'pov_header');

    // Exclusive children carry radios, not switches. The folder header is
    // the only Switch in this expanded exclusive group.
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byIcon(Icons.radio_button_off));
    await tester.pumpAndSettle();
    expect(selected, 'second_person');
  });

  testWidgets('locked group child cannot be toggled', (tester) async {
    const blocks = [
      StudioPresetBlock(id: 'header', title: '━ Core'),
      StudioPresetBlock(id: 'core', title: 'Core Directive', locked: true),
    ];
    final group = groupStudioPresetBlocks(blocks).single;
    var toggled = false;

    await tester.pumpWidget(
      _host(
        StudioBlockGroupRow(
          group: group,
          dragIndex: 0,
          isLast: true,
          onSelectExclusive: (_) {},
          onToggle: (_, _) => toggled = true,
          onEdit: (_) {},
          onDelete: (_) {},
          onDeleteGroup: (_) {},
          onMoveBlock: (_, _) {},
          onToggleGroup: (_) {},
        ),
      ),
    );

    await tester.tap(find.text('Core'));
    await tester.pumpAndSettle();

    // Two switches after expansion: the folder header toggle and the child
    // toggle. The locked child's switch is the one with onChanged == null.
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, hasLength(2));
    final lockedChildSwitch = switches.singleWhere(
      (s) => s.onChanged == null,
    );
    expect(lockedChildSwitch.value, isTrue);
    expect(toggled, isFalse);
  });

  testWidgets('CoT group shows a whole-group switch', (tester) async {
    const blocks = [
      StudioPresetBlock(
        id: 'cot_header_group_open',
        title: 'Opening tag',
        content: '<loomcot>',
        order: 0,
      ),
      StudioPresetBlock(
        id: 'cot_header',
        title: '━ CoT Selections',
        enabled: true,
        order: 1,
      ),
      StudioPresetBlock(
        id: 'cot_none',
        title: 'No CoT',
        enabled: true,
        order: 2,
      ),
      StudioPresetBlock(
        id: 'cot_full',
        title: 'Full CoT',
        enabled: false,
        order: 3,
      ),
      StudioPresetBlock(
        id: 'cot_header_group_close',
        title: 'Closing tag',
        content: '</loomcot>',
        order: 4,
      ),
    ];
    final group = groupStudioPresetBlocks(blocks).single;
    var groupToggled = false;

    await tester.pumpWidget(
      _host(
        StudioBlockGroupRow(
          group: group,
          dragIndex: 0,
          isLast: true,
          onSelectExclusive: (_) {},
          onToggle: (_, _) {},
          onEdit: (_) {},
          onDelete: (_) {},
          onDeleteGroup: (_) {},
          onMoveBlock: (_, _) {},
          onToggleGroup: (_) => groupToggled = true,
        ),
      ),
    );

    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(groupToggled, isTrue);
  });

  testWidgets('non-CoT exclusive group has a whole-group switch', (
    tester,
  ) async {
    const blocks = [
      StudioPresetBlock(id: 'pov_header', title: '━ Point-of-View', order: 0),
      StudioPresetBlock(
        id: 'third',
        title: 'Third Person',
        enabled: true,
        order: 1,
      ),
    ];
    final group = groupStudioPresetBlocks(blocks).single;

    await tester.pumpWidget(
      _host(
        StudioBlockGroupRow(
          group: group,
          dragIndex: 0,
          isLast: true,
          onSelectExclusive: (_) {},
          onToggle: (_, _) {},
          onEdit: (_) {},
          onDelete: (_) {},
          onDeleteGroup: (_) {},
          onMoveBlock: (_, _) {},
          onToggleGroup: (_) {},
        ),
      ),
    );

    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('folder delete icon triggers onDeleteGroup', (tester) async {
    const blocks = [
      StudioPresetBlock(id: 'folder_header', title: '━ My Folder', order: 0),
      StudioPresetBlock(id: 'child', title: 'Child', enabled: true, order: 1),
      StudioPresetBlock(
        id: 'folder_header_group_close',
        groupBoundary: 'close',
        order: 2,
      ),
    ];
    final group = groupStudioPresetBlocks(blocks).single;
    var deleted = false;

    await tester.pumpWidget(
      _host(
        StudioBlockGroupRow(
          group: group,
          dragIndex: 0,
          isLast: true,
          onSelectExclusive: (_) {},
          onToggle: (_, _) {},
          onEdit: (_) {},
          onDelete: (_) {},
          onDeleteGroup: (_) => deleted = true,
          onMoveBlock: (_, _) {},
          onToggleGroup: (_) {},
        ),
      ),
    );

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });
}
