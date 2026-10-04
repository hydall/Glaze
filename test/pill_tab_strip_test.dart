import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/glaze_tab_bar.dart';

/// Card #101 reports the third tab ("Images") as not centred, with a screenshot
/// nobody on this side can read. These measure what the strip actually does, so
/// the question back to the reporter can be specific instead of a guess.
void main() {
  Widget strip(List<String> labels, int active, {double width = 412}) =>
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: GlazeTabBar(
                  tabs: [
                    for (final label in labels)
                      GlazeTabItem(label: label, icon: Icons.circle_outlined),
                  ],
                  activeIndex: active,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

  /// The centre of a tab's icon+label group, in strip coordinates.
  double contentCentre(WidgetTester tester, String label) {
    final row = find.ancestor(
      of: find.text(label),
      matching: find.byType(Row),
    );
    final box = tester.getRect(row.first);
    return box.center.dx;
  }

  testWidgets('a three-tab strip centres every tab, Images included', (
    tester,
  ) async {
    await tester.pumpWidget(strip(['Info', 'Prompt Blocks', 'Images'], 0));
    await tester.pumpAndSettle();

    // Each tab slot is viewport / 2.35 wide (the strip scrolls past 2.35 tabs
    // so the next one is half-cut, which says "there is more here").
    const slot = 412 / 2.35;
    for (final (index, label) in [
      (0, 'Info'),
      (1, 'Prompt Blocks'),
      (2, 'Images'),
    ]) {
      final expected = tester.getRect(find.byType(GlazeTabBar)).left +
          slot * index +
          slot / 2;
      expect(
        contentCentre(tester, label),
        moreOrLessEquals(expected, epsilon: 1),
        reason: '"$label" should sit in the middle of its own slot',
      );
    }
  });

  testWidgets('the active pill sits over the tab it belongs to', (
    tester,
  ) async {
    await tester.pumpWidget(strip(['Info', 'Prompt Blocks', 'Images'], 2));
    await tester.pumpAndSettle();
    // The label and its pill share a centre: if they did not, the strip would
    // read as misaligned whichever of the two the eye followed.
    final pill = tester.getRect(find.byType(AnimatedPositioned).first);
    expect(
      contentCentre(tester, 'Images'),
      moreOrLessEquals(pill.center.dx, epsilon: 1),
    );
  });

  testWidgets('two tabs divide the strip exactly in half', (tester) async {
    await tester.pumpWidget(strip(['Sent', 'Response'], 0));
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byType(GlazeTabBar));
    expect(
      contentCentre(tester, 'Sent'),
      moreOrLessEquals(bar.left + bar.width / 4, epsilon: 1),
    );
    expect(
      contentCentre(tester, 'Response'),
      moreOrLessEquals(bar.left + bar.width * 3 / 4, epsilon: 1),
    );
  });

  testWidgets('three tabs overflow the strip, so the third is clipped', (
    tester,
  ) async {
    await tester.pumpWidget(strip(['Info', 'Prompt Blocks', 'Images'], 0));
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byType(GlazeTabBar));
    // This is what a reader sees before scrolling: "Images" starts inside the
    // strip and runs past its right edge.
    final images = tester.getRect(
      find.ancestor(of: find.text('Images'), matching: find.byType(Row)).first,
    );
    expect(images.left, lessThan(bar.right));
    expect(images.right, greaterThan(bar.right));
  });
}
