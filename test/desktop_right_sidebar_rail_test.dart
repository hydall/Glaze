import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/chat/widgets/magic_drawer_widgets.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_right_sidebar.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_resizer.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';

/// Vue pins `.left-icon-strip` top-to-bottom (`top: 0; bottom: 0`) and stacks
/// its icons from the top. The Flutter rail lives in a `Row` beside the open
/// panel, and a `Row` centres its children by default — so the strip, which
/// shrink-wraps its icons, floated into the middle of the sidebar with a gap
/// above the first icon.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSidebar(
    WidgetTester tester, {
    required bool withPanel,
    double width = 320,
  }) async {
    final controller = RightSidebarController.fromPrefs(null);
    final router = GoRouter(
      routes: [
        GoRoute(
          // Not a /chat/ route, so the sidebar renders the tool strip rather
          // than the Magic Drawer (which would want a database).
          path: '/tools',
          builder: (_, _) => DesktopRightSidebar(width: width),
        ),
      ],
      initialLocation: '/tools',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rightSidebarControllerProvider.overrideWithValue(controller),
        ],
        child: MaterialApp.router(
          theme: ThemeData.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (withPanel) {
      final ref = ProviderScope.containerOf(
        tester.element(find.byType(DesktopRightSidebar)),
      );
      ref.read(rightSidebarPanelProvider.notifier).state = SidebarPanel(
        id: 'stub',
        builder: (_) => const Text('panel body'),
      );
      await tester.pumpAndSettle();
    }
  }

  testWidgets('the rail beside an open panel starts at the top', (
    tester,
  ) async {
    await pumpSidebar(tester, withPanel: true);
    expect(find.text('panel body'), findsOneWidget);

    final sidebar = tester.getRect(find.byType(DesktopRightSidebar));
    final firstIcon = tester.getRect(find.byType(MagicDrawerStripIcon).first);

    // The first icon sits flush with the sidebar's top edge, not floated down
    // by a centred Row.
    expect(firstIcon.top, moreOrLessEquals(sidebar.top, epsilon: 0.5));
  });

  testWidgets('the collapsed strip also starts at the top', (tester) async {
    // Below the collapse threshold the strip is the whole sidebar.
    await pumpSidebar(tester, withPanel: false, width: kSidebarCollapsedWidth);

    final sidebar = tester.getRect(find.byType(DesktopRightSidebar));
    final firstIcon = tester.getRect(find.byType(MagicDrawerStripIcon).first);

    expect(firstIcon.top, moreOrLessEquals(sidebar.top, epsilon: 0.5));
  });
}
