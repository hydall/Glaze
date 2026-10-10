import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

/// A floating window is a [DetachedShellHost] that draws chrome around the
/// hosted screen. The sheet inside then fills the frame it is given; a
/// [SheetView.centerContent] body splits the leftover space instead of packing
/// against the top.
Widget _window({required bool centerContent}) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: Center(
        child: SizedBox(
          width: 400,
          height: 600,
          child: DetachedShellHost(
            hasChrome: true,
            headerBranch: kDetachedChromeBranch,
            child: SheetView(
              fitContent: true,
              centerContent: centerContent,
              body: const SizedBox(
                key: ValueKey('body'),
                height: 80,
                child: ColoredBox(color: Colors.red),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a centered fit-content body sits in the middle of the window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_window(centerContent: true));
    await tester.pumpAndSettle();

    final frame = tester.getRect(find.byType(DetachedShellHost));
    final body = tester.getRect(find.byKey(const ValueKey('body')));
    expect(body.center.dy, moreOrLessEquals(frame.center.dy, epsilon: 1));
  });

  testWidgets('without centerContent the body still packs to the top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_window(centerContent: false));
    await tester.pumpAndSettle();

    final frame = tester.getRect(find.byType(DetachedShellHost));
    final body = tester.getRect(find.byKey(const ValueKey('body')));
    expect(body.top, moreOrLessEquals(frame.top, epsilon: 1));
  });
}
