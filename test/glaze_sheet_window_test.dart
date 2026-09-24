import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:glaze_flutter/shared/widgets/glaze_bottom_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_sheet.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

Widget _desktopApp({required Widget Function(BuildContext) builder}) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: DesktopScope(
        isDesktop: true,
        child: Scaffold(
          body: Builder(builder: builder),
        ),
      ),
    ),
  );
}

Finder _openButton() => find.byKey(const ValueKey('open'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('showGlazeSheet opens a centered window, not a bottom sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _desktopApp(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => showGlazeSheet<void>(
              context: context,
              builder: (_) => const Text('sheet content'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(_openButton());
    await tester.pumpAndSettle();

    expect(find.text('sheet content'), findsOneWidget);
    // No Material bottom sheet route was built.
    expect(find.byType(BottomSheet), findsNothing);

    // The window is horizontally centered and capped at the sheet width.
    final window = tester.getRect(find.byType(GlassSurface));
    expect(window.center.dx, moreOrLessEquals(800, epsilon: 1));
    expect(window.width, moreOrLessEquals(640, epsilon: 1));
  });

  testWidgets('a hosted SheetView hands its header to the window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _desktopApp(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => showGlazeSheet<void>(
              context: context,
              builder: (_) => const SheetView(
                title: 'Cloud sync',
                showBack: true,
                body: Text('sheet body'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(_openButton());
    await tester.pumpAndSettle();

    expect(find.text('sheet body'), findsOneWidget);
    // The window's own title bar shows the sheet's title; the sheet draws no
    // second header inside the frame.
    expect(find.text('Cloud sync'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a rich GlazeBottomSheet opens as a window on desktop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _desktopApp(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () => GlazeBottomSheet.show<void>(
              context,
              title: 'Sheet',
              child: const Text('rich content'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(_openButton());
    await tester.pumpAndSettle();

    expect(find.text('rich content'), findsOneWidget);
    expect(find.byType(GlazeSheetWindow), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });
}
