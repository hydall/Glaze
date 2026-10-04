import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/widgets/glaze_spinner.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('falls back to the default diameter without a size or tight '
      'constraints', (tester) async {
    await tester.pumpWidget(_host(const GlazeSpinner()));

    expect(
      tester.getSize(find.byType(GlazeSpinner)),
      const Size.square(GlazeSpinner.defaultSize),
    );
  });

  testWidgets('adopts tight parent constraints', (tester) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 18, height: 18, child: GlazeSpinner())),
    );

    expect(tester.getSize(find.byType(GlazeSpinner)), const Size.square(18));
  });

  testWidgets('an explicit size sets the diameter under loose constraints', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const GlazeSpinner(size: 24)));

    expect(tester.getSize(find.byType(GlazeSpinner)), const Size.square(24));
  });

  testWidgets('shrinks below the default when the parent is smaller', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const SizedBox(width: 12, height: 12, child: GlazeSpinner())),
    );

    expect(tester.getSize(find.byType(GlazeSpinner)), const Size.square(12));
  });

  testWidgets('keeps animating while indeterminate', (tester) async {
    await tester.pumpWidget(_host(const GlazeSpinner()));

    // A live ticker means pumpAndSettle would never return; the spinner must
    // still be scheduling frames.
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('settles once a determinate value is given', (tester) async {
    await tester.pumpWidget(_host(const GlazeSpinner(value: 0.4)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('stops and restarts the ticker as value comes and goes', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const GlazeSpinner()));
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pumpWidget(_host(const GlazeSpinner(value: 0.5)));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(_host(const GlazeSpinner()));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('paints the extremes of both modes without error', (
    tester,
  ) async {
    for (final child in const [
      GlazeSpinner(size: 4),
      GlazeSpinner(size: 200),
      GlazeSpinner(value: 0),
      GlazeSpinner(value: 1),
      GlazeSpinner(glow: false, trackColor: Colors.transparent),
      GlazeSpinner(color: Colors.white70, semanticsLabel: 'Loading'),
    ]) {
      await tester.pumpWidget(_host(child));
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull, reason: '$child');
    }
  });
}
