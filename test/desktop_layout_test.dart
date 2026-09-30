import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/desktop/desktop_floating_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/desktop_window_geometry.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_resizer.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';
import 'package:glaze_flutter/shared/shell/desktop/sidebar_tool_panels.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
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
    Future<bool> reportsDesktop(WidgetTester tester, Size size) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late bool isDesktop;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopDetection(
            child: Builder(
              builder: (context) {
                isDesktop = isDesktopLayout(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      return isDesktop;
    }

    testWidgets('touch devices use desktop only in landscape', (tester) async {
      // Phone held upright.
      expect(await reportsDesktop(tester, const Size(400, 800)), isFalse);
      // A tablet upright stays on the phone layout even when its width clears
      // the breakpoint on paper.
      expect(await reportsDesktop(tester, const Size(800, 1280)), isFalse);
      // Rotating the tablet to landscape turns on the desktop layout…
      expect(await reportsDesktop(tester, const Size(1280, 800)), isTrue);
      // …and the 11" tablet's own portrait size is below the breakpoint anyway.
      expect(
        await reportsDesktop(
          tester,
          const Size(kTabletShortestSideBreakpoint, 960),
        ),
        isFalse,
      );
    });

    testWidgets('desktop windows keep the width rule in portrait', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        // A wide window is desktop regardless of shape.
        expect(
          await reportsDesktop(
            tester,
            const Size(kDesktopWidthBreakpoint + 100, 600),
          ),
          isTrue,
        );
        // A tall window on a portrait monitor is still desktop, not a tablet.
        expect(await reportsDesktop(tester, const Size(900, 1400)), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
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

  group('floating windows', () {
    ProviderContainer makeContainer() {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return container;
    }

    test('drilling in stays inside the window and pops back', () {
      final container = makeContainer();
      final windows = container.read(desktopWindowsProvider.notifier);

      expect(windows.isOpen, isFalse);

      final id = windows.open('menu');
      expect(windows.focused?.activeView, 'menu');
      expect(windows.focused?.canGoBack, isFalse);

      windows.push(id, 'settings');
      expect(windows.focused?.activeView, 'settings');
      expect(windows.focused?.canGoBack, isTrue);

      windows.pop(id);
      expect(windows.focused?.activeView, 'menu');

      // Popping the root closes the window rather than leaving it empty.
      windows.pop(id);
      expect(windows.isOpen, isFalse);
    });

    test('opening a view already on screen raises its window', () {
      final container = makeContainer();
      final windows = container.read(desktopWindowsProvider.notifier);

      final menu = windows.open('menu');
      final about = windows.open('about');
      expect(container.read(desktopWindowsProvider), hasLength(2));
      expect(windows.focused?.id, about);

      expect(windows.open('menu'), menu);
      expect(container.read(desktopWindowsProvider), hasLength(2));
      expect(windows.focused?.id, menu);

      // …unless a new window is asked for explicitly.
      windows.open('menu', newWindow: true);
      expect(container.read(desktopWindowsProvider), hasLength(3));
    });

    test('windows keep their own stacks and switch focus', () {
      final container = makeContainer();
      final windows = container.read(desktopWindowsProvider.notifier);

      final a = windows.open('menu');
      windows.push(a, 'settings');
      final b = windows.open('sync');
      expect(windows.focused?.id, b);

      windows.cycle();
      expect(windows.focused?.id, a);
      expect(windows.focused?.activeView, 'settings');

      windows.cycle(backwards: true);
      expect(windows.focused?.id, b);

      windows.close(b);
      expect(windows.focused?.id, a);
    });

    test('minimized windows give up focus and come back on focus', () {
      final container = makeContainer();
      final windows = container.read(desktopWindowsProvider.notifier);

      final a = windows.open('menu');
      final b = windows.open('about');
      windows.minimize(b);
      expect(windows.focused?.id, a);

      windows.minimize(a);
      expect(windows.focused, isNull);
      expect(windows.isOpen, isTrue);

      windows.focus(b);
      expect(windows.focused?.id, b);
      expect(windows.byId(b)?.minimized, isFalse);
    });

    test('detaching splits the top view into its own window', () {
      final container = makeContainer();
      final windows = container.read(desktopWindowsProvider.notifier);

      final a = windows.open('menu');
      windows.setRect(a, const Rect.fromLTWH(100, 100, 600, 500));
      expect(windows.detach(a), isNull, reason: 'nothing to split off');

      windows.push(a, 'settings');
      final b = windows.detach(a)!;
      expect(windows.byId(a)?.stack, ['menu']);
      expect(windows.byId(b)?.stack, ['settings']);
      expect(windows.byId(b)?.rect, const Rect.fromLTWH(132, 132, 600, 500));
      expect(windows.focused?.id, b);
    });

    test('a reopened window comes back where it was left', () {
      final container = makeContainer();
      final windows = container.read(desktopWindowsProvider.notifier);
      const rect = Rect.fromLTWH(40, 60, 500, 400);

      final id = windows.open('menu');
      windows.setRect(id, rect);
      windows.close(id);

      final reopened = windows.open('menu');
      expect(windows.byId(reopened)?.rect, rect);
    });

    test('every floating view has a phone route to fall back to', () {
      for (final id in desktopFloatingViews.keys) {
        expect(desktopFloatingViews[id], startsWith('/'));
      }
    });

    test('each window publishes its header under its own branch', () {
      expect(desktopWindowHeaderBranch(1), isNot(desktopWindowHeaderBranch(2)));
      expect(desktopWindowHeaderBranch(1), lessThan(kDetachedChromeBranch));
    });
  });

  group('window geometry', () {
    const bounds = Size(1200, 800);

    test('default rect is centered, capped and cascaded', () {
      final first = defaultWindowRect(bounds, const Size(620, 600));
      expect(first.center, bounds.center(Offset.zero));

      final second = defaultWindowRect(
        bounds,
        const Size(620, 600),
        cascade: 1,
      );
      expect(second.topLeft - first.topLeft, const Offset(28, 28));

      final huge = defaultWindowRect(bounds, const Size(5000, 5000));
      expect(huge.width, closeTo(bounds.width * 0.92, 0.001));
      expect(huge.height, closeTo(bounds.height * 0.92, 0.001));
    });

    test('clamping keeps the title bar reachable', () {
      final above = clampWindowRect(
        const Rect.fromLTWH(100, -200, 500, 400),
        bounds,
      );
      expect(above.top, 0);

      final farRight = clampWindowRect(
        const Rect.fromLTWH(5000, 5000, 500, 400),
        bounds,
      );
      expect(farRight.left, bounds.width - kDesktopWindowGrabMargin);
      expect(farRight.top, bounds.height - kDesktopWindowTitleBarHeight);

      final farLeft = clampWindowRect(
        const Rect.fromLTWH(-5000, 100, 500, 400),
        bounds,
      );
      expect(farLeft.right, kDesktopWindowGrabMargin);
    });

    test('resizing respects the minimum size and the bounds', () {
      const start = Rect.fromLTWH(100, 100, 600, 500);

      final grown = resizeWindowRect(
        start,
        WindowResizeEdge.bottomRight,
        const Offset(50, 40),
        bounds,
      );
      expect(grown, const Rect.fromLTWH(100, 100, 650, 540));

      final shrunk = resizeWindowRect(
        start,
        WindowResizeEdge.topLeft,
        const Offset(1000, 1000),
        bounds,
      );
      expect(shrunk.size, kDesktopWindowMinSize);
      expect(shrunk.bottomRight, start.bottomRight);

      final pastEdge = resizeWindowRect(
        start,
        WindowResizeEdge.left,
        const Offset(-1000, 0),
        bounds,
      );
      expect(pastEdge.left, 0);
      expect(pastEdge.right, start.right);
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
