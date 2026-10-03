import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/widgets/magic_drawer_list_row.dart';
import 'package:glaze_flutter/features/chat/widgets/magic_drawer_models.dart';
import 'package:glaze_flutter/features/chat/widgets/magic_drawer_widgets.dart';

/// The desktop right sidebar lays the chat drawer out as a list (Vue's
/// `.magic-drawer-sidebar`) rather than the mobile three-column grid.
void main() {
  const item = MagicDrawerCardItem(
    def: MagicDrawerItemDef(
      id: 'memory',
      label: 'Memory',
      icon: Icons.notes,
      category: MagicDrawerCategory.session,
    ),
    status: '3 entries',
  );

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SizedBox(width: 320, child: child)),
    ),
  );

  testWidgets('a list card is a full-width row with its label and status', (
    tester,
  ) async {
    var taps = 0;
    await pump(
      tester,
      MagicCard(
        item: item,
        editing: false,
        hovered: false,
        onTap: () => taps++,
        onDelete: () {},
        listRow: true,
      ),
    );

    expect(find.byType(MagicDrawerListRow), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('3 entries'), findsOneWidget);
    expect(tester.getSize(find.byType(MagicDrawerListRow)).width, 320);
    // No edit badge outside edit mode.
    expect(find.byType(MagicCardBadge), findsNothing);

    await tester.tap(find.text('Memory'));
    expect(taps, 1);
  });

  for (final status in ['3 entries', null]) {
    testWidgets(
      'the icon sits where the desktop strip draws it (status: $status)',
      (tester) async {
        // Opening a card shrinks the list to the 64px strip. The strip's rows
        // replace the list's one for one, so each icon must keep its place:
        // the same inset, the same row height, centred the same way — with a
        // status line under the label or without one.
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 320,
                    child: MagicCard(
                      item: MagicDrawerCardItem(def: item.def, status: status),
                      editing: false,
                      hovered: false,
                      onTap: () {},
                      onDelete: () {},
                      listRow: true,
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: MagicDrawerStripIcon(
                      icon: Icons.notes,
                      label: 'Memory',
                      height: kMagicDrawerRowHeight,
                      onTap: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        final icons = find.byIcon(Icons.notes);
        expect(icons, findsNWidgets(2));
        // Centres, not edges: the strip's square stretches its [Icon] to fill
        // it, so the two glyphs are centred alike in boxes of different size.
        final inList = tester.getCenter(icons.at(0));
        final inStrip = tester.getCenter(icons.at(1));
        expect(inList.dx, moreOrLessEquals(inStrip.dx - 320, epsilon: 0.5));
        expect(inList.dy, moreOrLessEquals(inStrip.dy, epsilon: 0.5));
        expect(
          tester.getSize(find.byType(MagicDrawerListRow)).height,
          kMagicDrawerRowHeight,
        );
      },
    );
  }

  testWidgets('edit mode puts the delete badge inline at the row end', (
    tester,
  ) async {
    var deleted = 0;
    await pump(
      tester,
      MagicCard(
        item: item,
        editing: true,
        hovered: false,
        onTap: () {},
        onDelete: () => deleted++,
        listRow: true,
      ),
    );

    final row = tester.getRect(find.byType(MagicDrawerListRow));
    final badge = tester.getRect(find.byType(MagicCardBadge));
    // Inside the row, not hanging off its corner the way a grid tile's does.
    expect(row.contains(badge.topLeft), isTrue);
    expect(row.contains(badge.bottomRight), isTrue);
    expect(badge.right, greaterThan(row.center.dx));

    await tester.tap(find.byType(MagicCardBadge));
    expect(deleted, 1);
  });

  testWidgets('the add card becomes an add row', (tester) async {
    var taps = 0;
    await pump(tester, AddMagicCard(onTap: () => taps++, listRow: true));

    expect(find.byType(MagicDrawerListRow), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(find.byType(MagicDrawerListRow));
    expect(taps, 1);
  });

  testWidgets('one column stacks the cells with no spacing', (tester) async {
    await pump(
      tester,
      const MagicCardGrid(
        columns: 1,
        runSpacing: 0,
        cells: [
          SizedBox(key: ValueKey('a'), width: 320, height: 52),
          SizedBox(key: ValueKey('b'), width: 320, height: 52),
        ],
      ),
    );

    final a = tester.getRect(find.byKey(const ValueKey('a')));
    final b = tester.getRect(find.byKey(const ValueKey('b')));
    expect(b.top, a.bottom);
    expect(b.left, a.left);
  });
}
