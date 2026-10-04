import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/shell/nav_bar_suppression_provider.dart';

void main() {
  testWidgets('releases suppression after the widget tree is finalized', (
    tester,
  ) async {
    Set<Object> suppression = const {};

    Widget app(Widget child) => ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            suppression = ref.watch(navBarSuppressionProvider);
            return child;
          },
        ),
      ),
    );

    await tester.pumpWidget(
      app(const NavBarSuppressor(child: SizedBox.shrink())),
    );
    await tester.pump();
    expect(suppression, hasLength(1));

    await tester.pumpWidget(app(const SizedBox.shrink()));
    expect(tester.takeException(), isNull);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(suppression, isEmpty);
  });
}
