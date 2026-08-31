import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/desktop/desktop_floating_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_resizer.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_tool_panels.dart';
import 'package:glaze_flutter/shared/widgets/responsive_grid.dart';

void main() {
  group('sidebar controllers', () {
    test('start from defaults when prefs have not resolved yet', () {
      final left = LeftSidebarController.fromPrefs(null);
      final right = RightSidebarController.fromPrefs(null);

      expect(left.width, LeftSidebarController.defaultWidth);
      expect(left.collapsed, isFalse);
      // Expanded by default, matching the Vue app — a collapsed right sidebar
      // in chat is just the icon strip.
      expect(right.collapsed, isFalse);
      expect(right.width, RightSidebarController.expandedDefault);
    });

    test('adopt stored widths once prefs arrive', () async {
      SharedPreferences.setMockInitialValues({
        'gz_left_sidebar_width': 340,
        'gz_left_sidebar_width_collapsed': '0',
        'gz_right_sidebar_width': 420,
        'gz_right_sidebar_width_collapsed': '0',
      });
      final prefs = await SharedPreferences.getInstance();

      final left = LeftSidebarController.fromPrefs(null);
      final right = RightSidebarController.fromPrefs(null);
      left.applyPrefs(prefs);
      right.applyPrefs(prefs);

      expect(left.width, 340);
      expect(right.width, 420);
    });

    test('double-click toggle collapses and persists', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final left = LeftSidebarController.fromPrefs(prefs);

      left.toggleCollapse(prefs);
      expect(left.collapsed, isTrue);
      expect(prefs.getString('gz_left_sidebar_width_collapsed'), '1');

      left.toggleCollapse(prefs);
      expect(left.collapsed, isFalse);
      expect(left.width, LeftSidebarController.defaultWidth);
      expect(prefs.getString('gz_left_sidebar_width_collapsed'), '0');
    });

    test('right sidebar keeps expanded and collapsed widths independent', () {
      final right = RightSidebarController.fromPrefs(null);

      // Drag in from expanded past the threshold: collapses, but the expanded
      // width it should spring back to is untouched.
      right.handleDragUpdate(80, false);
      expect(right.collapsed, isTrue);

      right.handleDragUpdate(300, true);
      expect(right.collapsed, isFalse);
      expect(right.width, 300);
    });
  });

  group('desktop breakpoint', () {
    testWidgets('DesktopScope reports desktop above the breakpoint', (
      tester,
    ) async {
      late bool wide;
      late bool narrow;

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              SizedBox(
                width: kDesktopWidthBreakpoint + 100,
                child: DesktopDetection(
                  child: Builder(
                    builder: (context) {
                      wide = isDesktopLayout(context);
                      return const SizedBox();
                    },
                  ),
                ),
              ),
              SizedBox(
                width: kDesktopWidthBreakpoint - 100,
                child: DesktopDetection(
                  child: Builder(
                    builder: (context) {
                      narrow = isDesktopLayout(context);
                      return const SizedBox();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      expect(wide, isTrue);
      expect(narrow, isFalse);
    });
  });

  group('responsive grid', () {
    test('fits more columns as the viewport grows', () {
      int columnsAt(double width) => ResponsiveGridDelegate(
        availableWidth: width,
        minCellExtent: 180,
        childAspectRatio: 2 / 3,
      ).crossAxisCount;

      // Phone width still gets the original two columns…
      expect(columnsAt(380), 2);
      // …while a desktop middle column stops blowing cards up to poster size.
      expect(columnsAt(760), 4);
      expect(columnsAt(1500), greaterThanOrEqualTo(7));
    });

    test('never drops below the minimum column count', () {
      final delegate = ResponsiveGridDelegate(
        availableWidth: 100,
        minCellExtent: 180,
        childAspectRatio: 1,
        minColumns: 3,
      );
      expect(delegate.crossAxisCount, 3);
    });
  });

  group('floating window stack', () {
    test('drilling in stays inside the window and pops back', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(desktopFloatingProvider);

      expect(controller.isOpen, isFalse);

      controller.open('menu');
      expect(controller.activeView, 'menu');
      expect(controller.canGoBack, isFalse);

      controller.push('settings');
      expect(controller.activeView, 'settings');
      expect(controller.canGoBack, isTrue);

      controller.pop();
      expect(controller.activeView, 'menu');

      // Popping the root closes the window rather than leaving it empty.
      controller.pop();
      expect(controller.isOpen, isFalse);
    });

    test('every floating view has a phone route to fall back to', () {
      for (final id in desktopFloatingViews.keys) {
        expect(desktopFloatingViews[id], startsWith('/'));
      }
    });
  });

  group('sidebar tool panels', () {
    /// Pumps a [Consumer] and returns its `ref`. The sidebar helpers take a
    /// `WidgetRef` (their real callers are widgets) and Riverpod 3 seals that
    /// type, so a real element is the only way to get one. Mutations run after
    /// the pump — writing to a provider *during* build is forbidden.
    Future<WidgetRef> pumpRef(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('toggling the same tool twice closes the panel', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = await pumpRef(tester, container);

      final panel = sidebarToolPanel('presets');
      togglePanelInRightSidebar(ref, panel);
      expect(container.read(rightSidebarPanelProvider)?.id, 'presets');
      expect(container.read(rightSidebarOccupiedProvider), isTrue);

      togglePanelInRightSidebar(ref, panel);
      expect(container.read(rightSidebarPanelProvider), isNull);
      expect(container.read(rightSidebarOccupiedProvider), isFalse);
    });

    testWidgets('switching tools replaces the panel instead of stacking', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = await pumpRef(tester, container);

      togglePanelInRightSidebar(ref, sidebarToolPanel('api'));
      togglePanelInRightSidebar(ref, sidebarToolPanel('regex'));
      expect(container.read(rightSidebarPanelProvider)?.id, 'regex');
    });

    test('the strip lists exactly the five Vue tools', () {
      expect(sidebarTools.map((t) => t.id).toList(), [
        'personas',
        'presets',
        'api',
        'lorebooks',
        'regex',
      ]);
    });
  });
}
