import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/navigation/router.dart'
    show rootNavigatorKey;
import 'package:glaze_flutter/features/regex/stopped_regex_sheet.dart';

const _script = PresetRegex(id: 'tracker', name: ' fwn: info', regex: 'x');

/// Without EasyLocalization `.tr()` returns the key, so the assertions read
/// keys; the script name rides in the body's argument.
void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const Scaffold(),
        ),
      ),
    );
  }

  testWidgets('names the stopped script and closes on OK', (tester) async {
    await pumpApp(tester);

    final shown = showStoppedRegexSheet(const [_script]);
    await tester.pumpAndSettle();

    expect(find.text('regex_stopped_title'), findsOneWidget);
    expect(find.text('regex_stopped_open'), findsOneWidget);

    await tester.tap(find.text('regex_stopped_dismiss'));
    await tester.pumpAndSettle();
    await shown;

    expect(find.text('regex_stopped_title'), findsNothing);
  });

  testWidgets('a second report while one is up is not stacked', (tester) async {
    await pumpApp(tester);

    final first = showStoppedRegexSheet(const [_script]);
    await tester.pumpAndSettle();
    await showStoppedRegexSheet(const [_script]);
    await tester.pumpAndSettle();

    expect(find.text('regex_stopped_title'), findsOneWidget);

    await tester.tap(find.text('regex_stopped_dismiss'));
    await tester.pumpAndSettle();
    await first;
  });
}
