import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/shell/header_scroll_hider.dart';

ScrollUpdateNotification _scrollTo(BuildContext context, double pixels, {double maxExtent = 5000}) {
  return ScrollUpdateNotification(
    metrics: FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: maxExtent,
      pixels: pixels,
      viewportDimension: 800,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    ),
    context: context,
  );
}

void main() {
  group('HeaderScrollHider', () {
    late HeaderScrollHider hider;
    late List<bool> emitted;

    testWidgets('hides on downward scroll and reveals on upward scroll', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));

      hider = HeaderScrollHider();
      emitted = <bool>[];

      hider.handle(_scrollTo(context, 400), emitted.add);
      expect(emitted, [true]);
      expect(hider.hidden, isTrue);

      hider.handle(_scrollTo(context, 200), emitted.add);
      expect(emitted, [true, false]);
      expect(hider.hidden, isFalse);
    });

    testWidgets('reset clears the hidden state so the next hide is not swallowed', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));

      hider = HeaderScrollHider();
      emitted = <bool>[];

      hider.handle(_scrollTo(context, 400), emitted.add);
      expect(hider.hidden, isTrue);

      hider.reset();
      expect(hider.hidden, isFalse);

      emitted.clear();
      hider.handle(_scrollTo(context, 400), emitted.add);
      hider.handle(_scrollTo(context, 600), emitted.add);
      expect(emitted, [true]);
    });

    testWidgets('reset absorbs the jump to a different view scroll offset', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));

      hider = HeaderScrollHider();
      emitted = <bool>[];

      hider.reset();

      hider.handle(_scrollTo(context, 2000), emitted.add);
      expect(emitted, isEmpty);
      expect(hider.hidden, isFalse);

      hider.handle(_scrollTo(context, 2100), emitted.add);
      expect(emitted, [true]);
    });

    testWidgets('ignores horizontal scrollables', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));

      hider = HeaderScrollHider();
      emitted = <bool>[];

      hider.handle(
        ScrollUpdateNotification(
          metrics: FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 5000,
            pixels: 400,
            viewportDimension: 800,
            axisDirection: AxisDirection.right,
            devicePixelRatio: 1,
          ),
          context: context,
        ),
        emitted.add,
      );
      expect(emitted, isEmpty);
    });
  });
}
