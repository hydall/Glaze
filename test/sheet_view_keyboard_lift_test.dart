import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/widgets/sheet_view.dart';
import 'package:glaze_flutter/shared/widgets/top_edge_blur.dart';

/// The sheet answers the keyboard by tracking its inset, not by running a
/// second height animation of its own. The two used to overlap — the keyboard
/// slid the content up while a 350 ms tween grew the sheet on another curve —
/// and the body was resized twice per toggle, which read as a flicker in every
/// sheet with a text field (the Memory sheet's Summary tab above all).
void main() {
  const full = 1000.0;
  const collapsed = full * 0.85;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSheet(
    WidgetTester tester, {
    bool startExpanded = false,
    Widget body = const Text('sheet body'),
  }) async {
    tester.view.physicalSize = const Size(700, full);
    tester.view.devicePixelRatio = 1;
    // A status bar to pad against: the pad the sheet fades in as it reaches
    // fullscreen is what used to rebuild the body on every frame.
    tester.view.padding = const FakeViewPadding(top: 60);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => SheetView(
                    title: 'Memory',
                    startExpanded: startExpanded,
                    body: body,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(SheetView)).height;

  void showKeyboard(WidgetTester tester, double height) {
    tester.view.viewInsets = FakeViewPadding(bottom: height);
  }

  testWidgets('the sheet grows with the keyboard inset and shrinks back', (
    tester,
  ) async {
    await pumpSheet(tester);
    expect(sheetHeight(tester), moreOrLessEquals(collapsed, epsilon: 0.01));

    // Half-way through the keyboard's own animation: the sheet has grown by
    // exactly what the keyboard covers, so the visible body is unchanged.
    showKeyboard(tester, 50);
    await tester.pump();
    expect(sheetHeight(tester), moreOrLessEquals(collapsed + 50, epsilon: 0.01));

    // The lift stops at fullscreen — it never overshoots the screen.
    showKeyboard(tester, 300);
    await tester.pump();
    expect(sheetHeight(tester), moreOrLessEquals(full, epsilon: 0.01));

    // And it is gone in the same frame the inset reaches zero: no 350 ms
    // collapse tween trailing behind the keyboard.
    showKeyboard(tester, 0);
    await tester.pump();
    expect(sheetHeight(tester), moreOrLessEquals(collapsed, epsilon: 0.01));
  });

  testWidgets('the edge blur stays on while the keyboard moves', (
    tester,
  ) async {
    await pumpSheet(tester);
    bool blurOn() =>
        tester.widget<TopEdgeBlur>(find.byType(TopEdgeBlur)).enabled;
    expect(blurOn(), isTrue);

    // The blur is not something the sheet trades away for frames — it stays
    // on through the whole keyboard animation.
    showKeyboard(tester, 100);
    await tester.pump();
    expect(blurOn(), isTrue);

    showKeyboard(tester, 0);
    await tester.pump();
    expect(blurOn(), isTrue);
  });

  testWidgets('the body is not rebuilt while the keyboard lifts the sheet', (
    tester,
  ) async {
    var builds = 0;
    await pumpSheet(
      tester,
      body: Builder(
        builder: (context) {
          builds++;
          // What a real sheet body does with the inset it is handed.
          final top = MediaQuery.paddingOf(context).top;
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: const Text('sheet body'),
          );
        },
      ),
    );
    final settled = builds;

    // The sheet resizes on every one of these frames. The header inset it
    // hands the body must not move with it, or a big form rebuilds its whole
    // tree per frame — which is what dropped frames in the API sheet.
    for (final inset in [20.0, 60.0, 140.0, 300.0, 0.0]) {
      showKeyboard(tester, inset);
      await tester.pump();
    }
    expect(builds, settled);
  });

  testWidgets('a sheet the user already expanded stays expanded', (
    tester,
  ) async {
    await pumpSheet(tester, startExpanded: true);
    expect(sheetHeight(tester), moreOrLessEquals(full, epsilon: 0.01));

    showKeyboard(tester, 300);
    await tester.pump();
    expect(sheetHeight(tester), moreOrLessEquals(full, epsilon: 0.01));

    showKeyboard(tester, 0);
    await tester.pump();
    expect(sheetHeight(tester), moreOrLessEquals(full, epsilon: 0.01));
  });
}
