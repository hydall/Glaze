import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
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
}
