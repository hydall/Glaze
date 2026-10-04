import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

/// The desktop floating window already frames whatever it hosts, so the menu
/// groups inside it drop their own rounded cards and side gutters — otherwise
/// the content reads as a card of cards — and their glass: over the window's
/// own fill a second tint marked out a band only as tall as the groups. Only
/// the rule under each group still separates one from the next.
Widget _host({required bool hasChrome}) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: DetachedShellHost(
          hasChrome: hasChrome,
          child: const MenuGroup(items: [Text('row')]),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a group in the floating window runs edge to edge', (
    tester,
  ) async {
    await tester.pumpWidget(_host(hasChrome: true));
    await tester.pumpAndSettle();

    expect(find.byType(GlassSurface), findsNothing);
    // Only the bottom rule survives — no left/right edges.
    final rule = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(MenuGroup),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).border != null,
        ),
      ),
    );
    final border = (rule.decoration as BoxDecoration).border! as Border;
    expect(border.left, BorderSide.none);
    expect(border.right, BorderSide.none);
    expect(border.bottom, isNot(BorderSide.none));

    final host = tester.getRect(find.byType(DetachedShellHost));
    final group = tester.getRect(find.byType(MenuGroup));
    expect(group.left, moreOrLessEquals(host.left, epsilon: 0.5));
    expect(group.right, moreOrLessEquals(host.right, epsilon: 0.5));
  });

  testWidgets('a group outside the window keeps its card', (tester) async {
    await tester.pumpWidget(_host(hasChrome: false));
    await tester.pumpAndSettle();

    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.borderRadius, BorderRadius.circular(20));

    final host = tester.getRect(find.byType(DetachedShellHost));
    final card = tester.getRect(find.byType(GlassSurface));
    expect(card.left, greaterThan(host.left));
    expect(card.right, lessThan(host.right));
  });
}
