import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/requests/inspector_insets.dart';
import 'package:glaze_flutter/features/chat/widgets/requests/inspector_message.dart';
import 'package:glaze_flutter/features/chat/widgets/requests/request_body_view.dart';

/// `SheetView` does not pad its body against the Android nav bar — it publishes
/// the inset through `MediaQuery.padding.bottom` and expects the body to
/// consume it, so rows scroll behind the nav bar while the last one rests above
/// it. A scroll view that passes its own `padding` *replaces* the
/// MediaQuery-derived padding rather than adding to it, which silently dropped
/// the inset in every one of the inspector's scroll surfaces and put the bottom
/// row — and the buttons on it — under the nav bar.
void main() {
  group('withInspectorBottomInset', () {
    Future<EdgeInsets> resolve(WidgetTester tester, double inset) async {
      late EdgeInsets padding;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(padding: EdgeInsets.only(bottom: inset)),
          child: Builder(
            builder: (context) {
              padding = withInspectorBottomInset(
                context,
                const EdgeInsets.fromLTRB(12, 12, 12, 24),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return padding;
    }

    testWidgets('adds the published inset to the padding asked for', (
      tester,
    ) async {
      final padding = await resolve(tester, 48);
      expect(padding.bottom, 24 + 48);
      // Nothing else moves.
      expect(padding.left, 12);
      expect(padding.right, 12);
      expect(padding.top, 12);
    });

    testWidgets('leaves the padding alone where there is no inset', (
      tester,
    ) async {
      expect((await resolve(tester, 0)).bottom, 24);
    });
  });

  group('RequestBodyView', () {
    Future<double> trailingGap(WidgetTester tester, double inset) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(padding: EdgeInsets.only(bottom: inset)),
            child: Scaffold(
              body: RequestBodyView(
                tokens: 10,
                contextSize: 0,
                paramsTitle: 'Parameters',
                params: const [],
                messages: const [
                  InspectorMessage(role: 'user', content: 'only message'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The trailing spacer is the surface's bottom padding: a CustomScrollView
      // has no `padding` of its own to grow.
      final gaps = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((box) => box.width == null && box.height != null)
          .map((box) => box.height!)
          .toList();
      return gaps.reduce((a, b) => a > b ? a : b);
    }

    testWidgets('grows its trailing gap by the nav-bar inset', (tester) async {
      expect(await trailingGap(tester, 0), 24);
      expect(await trailingGap(tester, 48), 24 + 48);
    });
  });
}
