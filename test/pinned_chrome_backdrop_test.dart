import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/top_edge_blur.dart';

void main() {
  testWidgets('keeps the pinned chrome scrim when blur is disabled', (
    tester,
  ) async {
    const tint = Color(0xE0112233);

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 320,
          height: 240,
          child: TopEdgeBlur(
            enabled: false,
            height: 80,
            tintColor: tint,
            child: ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );

    final decorated = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(TopEdgeBlur),
        matching: find.byType(DecoratedBox),
      ),
    );
    final gradient = (decorated.decoration as BoxDecoration).gradient!;

    expect(gradient.colors.first, tint);
    expect(gradient.colors.last.a, 0);
    expect(tester.getSize(find.byType(DecoratedBox)).height, 80);
  });

  test('all pinned chrome containers use a strong shared scrim', () {
    final sources = [
      File('lib/shared/widgets/sheet_view.dart').readAsStringSync(),
      File('lib/shared/widgets/glaze_bottom_sheet.dart').readAsStringSync(),
      File(
        'lib/features/chat/widgets/drawer_panel_scaffold.dart',
      ).readAsStringSync(),
    ];

    for (final source in sources) {
      final backdropStart = source.indexOf('TopEdgeBlur(');
      final backdropEnd = source.indexOf('child:', backdropStart);
      final backdrop = source.substring(backdropStart, backdropEnd);

      expect(backdropStart, isNonNegative);
      expect(backdrop, contains('alpha: 0.88'));
      expect(backdrop, isNot(contains('alpha: 0.4')));
    }
  });

  test('route SheetView applies the backdrop before its fixed header', () {
    final source = File(
      'lib/shared/widgets/sheet_view.dart',
    ).readAsStringSync();
    final routeStart = source.indexOf('if (!_inModalSheet)');
    final routeEnd = source.indexOf('return PopScope(', routeStart);
    final routeBranch = source.substring(routeStart, routeEnd);

    expect(routeBranch, contains('return TopEdgeBlur('));
    expect(routeBranch, contains('height: extraTop + 8'));
  });
}
