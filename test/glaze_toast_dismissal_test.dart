import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/widgets/glaze_toast.dart';

/// A toast must always leave the overlay again. The `Continue Failed` toast is
/// raised from a background generation, so its entry can be inserted into an
/// overlay that is not producing frames — it is then built minutes later, when
/// the app is resumed, with every timer that was supposed to take it down long
/// since spent. Before the dismissal was tied to the entry rather than to the
/// widget state, that left the red chip pinned on screen until the next app
/// restart.
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    GlazeToast.hide();
  });

  Widget buildTestApp() {
    return ProviderScope(
      child: MaterialApp(
        home: Overlay(
          key: toastOverlayKey,
          initialEntries: [
            OverlayEntry(builder: (_) => const Scaffold(body: SizedBox())),
          ],
        ),
      ),
    );
  }

  testWidgets('a toast replaced before its first frame never appears', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp());

    // No pump in between: the first entry is inserted and replaced within the
    // same frame, so its animator state is never created.
    GlazeToast.showWithoutContext('First');
    GlazeToast.showWithoutContext('Second');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(
      find.text('First'),
      findsNothing,
      reason: 'The replaced toast must be dropped, not left in the overlay',
    );
    expect(find.text('Second'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2500));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsNothing);
  });

  testWidgets('hide() removes a toast that was never built', (tester) async {
    await tester.pumpWidget(buildTestApp());

    GlazeToast.showWithoutContext('Unbuilt');
    GlazeToast.hide();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(find.text('Unbuilt'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(
      find.text('Unbuilt'),
      findsNothing,
      reason: 'A hidden toast must not surface on a later frame',
    );
  });

  testWidgets('the countdown starts when the toast is first built', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestApp());

    GlazeToast.showWithoutContext('Continue Failed', duration: 2000);

    // Stands in for the app sitting in the background: the entry is inserted,
    // but the overlay builds it only much later.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Continue Failed'),
      findsOneWidget,
      reason: 'The notice is still owed to the user once frames resume',
    );

    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(
      find.text('Continue Failed'),
      findsNothing,
      reason: 'It must still time out on its own after being shown',
    );
  });

  testWidgets('a burst of toasts leaves nothing behind', (tester) async {
    await tester.pumpWidget(buildTestApp());

    for (var i = 0; i < 5; i++) {
      GlazeToast.showWithoutContext('Continue Failed $i', duration: 4000);
      // Every other burst member is replaced before the overlay can build it,
      // which is what a run of failures in quick succession looks like.
      if (i.isOdd) await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(
      find.textContaining('Continue Failed'),
      findsOneWidget,
      reason: 'Only the newest toast of a burst stays on screen',
    );

    await tester.pump(const Duration(milliseconds: 4000));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(
      find.textContaining('Continue Failed'),
      findsNothing,
      reason: 'Every toast of the burst must expire without a restart',
    );
  });
}
