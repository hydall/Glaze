import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_groups.dart';
import 'package:glaze_flutter/features/studio/widgets/studio_preset_group_tile.dart';

void main() {
  testWidgets('exclusive group renders a dropdown and selects one option', (
    tester,
  ) async {
    const blocks = [
      StudioPresetBlock(
        id: 'pov_header_group_open',
        title: 'Opening tag',
        kind: 'group_open',
        content: '<loompov>',
        order: 0,
      ),
      StudioPresetBlock(id: 'pov_header', title: '━🧍 Point-of-View', order: 1),
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
        kind: 'group_close',
        content: '</loompov>',
        order: 4,
      ),
    ];
    final group = groupStudioPresetBlocks(blocks).single;
    String? selected;
    StudioPresetBlock? edited;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudioPresetGroupTile(
            group: group,
            onSelectExclusive: (id) => selected = id,
            onToggle: (_, _) {},
            onEdit: (block) => edited = block,
          ),
        ),
      ),
    );

    expect(find.text('Point-of-View'), findsOneWidget);
    expect(find.text('Third Person Narrator'), findsOneWidget);

    await tester.tap(find.text('Point-of-View'));
    await tester.pumpAndSettle();

    expect(find.text('Opening tag'), findsOneWidget);
    expect(find.text('<loompov>'), findsOneWidget);
    expect(find.text('Closing tag'), findsOneWidget);
    expect(find.text('</loompov>'), findsOneWidget);

    await tester.tap(find.text('<loompov>'));
    expect(edited?.id, 'pov_header_group_open');

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Person').last);
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
      MaterialApp(
        home: Scaffold(
          body: StudioPresetGroupTile(
            group: group,
            onSelectExclusive: (_) {},
            onToggle: (_, _) => toggled = true,
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Core'));
    await tester.pumpAndSettle();

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.onChanged, isNull);
    expect(toggled, isFalse);
  });
}
