import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/desktop/sidebar_sheet_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_background.dart';
import 'package:glaze_flutter/shared/widgets/glaze_scaffold.dart';
import 'package:glaze_flutter/shared/widgets/glaze_sheet.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

/// The desktop floating window draws its own title bar, so a [SheetView] shown
/// inside it (Cloud sync, Backups) must not draw a second header below that
/// bar — it hands its title and actions to the window instead. The right
/// sidebar has no title bar and its panels keep their own headers.
Widget _host({
  required bool hasChrome,
  List<SheetViewAction> actions = const [],
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: DetachedShellHost(
          hasChrome: hasChrome,
          child: SheetView(
            title: 'Cloud sync',
            showBack: true,
            actions: actions,
            body: const Text('sheet body'),
          ),
        ),
      ),
    ),
  );
}

ShellHeaderEntry? _chromeClaim(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.text('sheet body')),
  );
  return resolveShellHeader(
    container.read(shellHeaderProvider),
    kDetachedChromeBranch,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a chrome-drawing host takes over the sheet header', (
    tester,
  ) async {
    await tester.pumpWidget(_host(hasChrome: true));
    await tester.pumpAndSettle();

    expect(find.text('sheet body'), findsOneWidget);
    // Neither the title nor the back button is drawn inside the frame.
    expect(find.text('Cloud sync'), findsNothing);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);

    final claim = _chromeClaim(tester);
    expect(claim, isNotNull);
    expect(claim!.config.title, 'Cloud sync');
  });

  testWidgets('actions reach the host title bar', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        hasChrome: true,
        actions: [
          SheetViewAction(
            icon: const Icon(Icons.search),
            onPressed: () => taps++,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Not in the sheet itself…
    expect(find.byIcon(Icons.search), findsNothing);

    // …but in the claim the host renders, wired to the sheet's callback.
    final actions = _chromeClaim(tester)!.config.actions;
    expect(actions, hasLength(1));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: Row(children: actions!)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search));
    expect(taps, 1);
  });

  testWidgets('a host without chrome leaves the header alone', (tester) async {
    await tester.pumpWidget(_host(hasChrome: false));
    await tester.pumpAndSettle();

    expect(find.text('Cloud sync'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    expect(_chromeClaim(tester), isNull);
  });

  // A sheet hosted in the right sidebar fills a fixed column, so its header
  // runs edge to edge with square corners like the desktop shell's tab header.
  // The inset, 20px-rounded pill is the phone treatment and read as a bar
  // floating loose inside the column.
  testWidgets('a sheet hosted in the sidebar draws a flush header', (
    tester,
  ) async {
    await tester.pumpWidget(_host(hasChrome: false));
    await tester.pumpAndSettle();

    final appBar = tester.widget<GlazeAppBar>(find.byType(GlazeAppBar));
    expect(appBar.borderRadius, BorderRadius.zero);

    // Edge to edge: no side gutter between the column and the header.
    final host = tester.getRect(find.byType(SheetView));
    final bar = tester.getRect(find.byType(GlazeAppBar));
    expect(bar.left, moreOrLessEquals(host.left, epsilon: 0.5));
    expect(bar.right, moreOrLessEquals(host.right, epsilon: 0.5));
  });

  // A panel's back button is drawn over the strip beside it (Vue's sheet
  // header ran across the strip), so the panel's own header draws none and
  // hands the strip its back step instead.
  group('in a sidebar panel', () {
    Future<SidebarPanelBack> pumpPanel(
      WidgetTester tester, {
      VoidCallback? onBack,
      VoidCallback? onClose,
    }) async {
      final back = SidebarPanelBack();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: DetachedShellHost(
                child: SidebarPanelScope(
                  onClose: onClose ?? () {},
                  back: back,
                  child: SheetView(
                    title: 'Memory',
                    onBack: onBack,
                    body: const Text('sheet body'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return back;
    }

    testWidgets('the header has no back button and no logo slot', (
      tester,
    ) async {
      await pumpPanel(tester);

      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
      // The title starts at the edge gutter, not after an empty 52px slot.
      final bar = tester.getRect(find.byType(GlazeAppBar));
      final title = tester.getRect(find.text('Memory'));
      expect(title.left - bar.left, moreOrLessEquals(16, epsilon: 0.5));
    });

    testWidgets('the strip runs the sheet back step', (tester) async {
      var steps = 0;
      var closes = 0;
      final back = await pumpPanel(
        tester,
        onBack: () => steps++,
        onClose: () => closes++,
      );

      back.run(() => fail('the sheet claimed the back step'));
      expect(steps, 1);
      expect(closes, 0);
    });

    testWidgets('without a back step of its own, back closes the panel', (
      tester,
    ) async {
      var closes = 0;
      final back = await pumpPanel(tester, onClose: () => closes++);

      back.run(() => fail('the sheet claimed the back step'));
      expect(closes, 1);
    });

    testWidgets('the claim goes with the sheet', (tester) async {
      final back = await pumpPanel(tester);
      await tester.pumpWidget(const SizedBox());

      var fallbacks = 0;
      back.run(() => fallbacks++);
      expect(fallbacks, 1);
    });
  });

  testWidgets('an ordinary route keeps the inset pill header', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: SheetView(
              title: 'Cloud sync',
              showBack: true,
              body: Text('sheet body'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final appBar = tester.widget<GlazeAppBar>(find.byType(GlazeAppBar));
    expect(appBar.borderRadius, const BorderRadius.all(Radius.circular(20)));

    final host = tester.getRect(find.byType(SheetView));
    final bar = tester.getRect(find.byType(GlazeAppBar));
    expect(bar.left, greaterThan(host.left));
  });

  // Every window shows its own glass behind the screen in it, the way the
  // Settings window does: a screen painting the app background or a solid
  // fill there made each window look different.
  group('window background', () {
    Finder surfaceFill(WidgetTester tester) {
      final surface = Theme.of(
        tester.element(find.text('sheet body')),
      ).colorScheme.surface;
      return find.descendant(
        of: find.byType(SheetView),
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == surface,
        ),
      );
    }

    testWidgets('a sheet in a window paints no background of its own', (
      tester,
    ) async {
      await tester.pumpWidget(_host(hasChrome: true));
      await tester.pumpAndSettle();
      expect(find.byType(GlazeBackground), findsNothing);
    });

    testWidgets('a sheet in the sidebar keeps the app background', (
      tester,
    ) async {
      await tester.pumpWidget(_host(hasChrome: false));
      await tester.pumpAndSettle();
      expect(find.byType(GlazeBackground), findsOneWidget);
    });

    Widget sheetWindow({required bool chrome}) {
      const sheet = GlazeSheetWindowScope(
        contentSized: false,
        child: SheetView(title: 'Personas', body: Text('sheet body')),
      );
      return ProviderScope(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: chrome
                ? const DetachedShellHost(hasChrome: true, child: sheet)
                : sheet,
          ),
        ),
      );
    }

    testWidgets('a sheet window with a title bar is see-through', (
      tester,
    ) async {
      await tester.pumpWidget(sheetWindow(chrome: true));
      await tester.pumpAndSettle();
      expect(surfaceFill(tester), findsNothing);
    });

    testWidgets('a chrome-less sheet window keeps its solid fill', (
      tester,
    ) async {
      await tester.pumpWidget(sheetWindow(chrome: false));
      await tester.pumpAndSettle();
      expect(surfaceFill(tester), findsOneWidget);
    });

    Widget scaffold({required bool inWindow}) {
      const screen = GlazeScaffold(
        title: 'Content providers',
        body: Text('sheet body'),
      );
      return ProviderScope(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: inWindow
              ? const DetachedShellHost(hasChrome: true, child: screen)
              : screen,
        ),
      );
    }

    testWidgets('a scaffold in a window hands over header and background', (
      tester,
    ) async {
      await tester.pumpWidget(scaffold(inWindow: true));
      await tester.pumpAndSettle();
      expect(find.byType(GlazeBackground), findsNothing);
      expect(find.byType(GlazeAppBar), findsNothing);
      expect(_chromeClaim(tester)?.config.title, 'Content providers');
    });

    testWidgets('a scaffold elsewhere draws both itself', (tester) async {
      await tester.pumpWidget(scaffold(inWindow: false));
      await tester.pumpAndSettle();
      expect(find.byType(GlazeBackground), findsOneWidget);
      expect(find.byType(GlazeAppBar), findsOneWidget);
    });
  });
}
