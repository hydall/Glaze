import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/widgets/generic_editor.dart';

/// The prompt block editor in a desktop window: a few short fields and the
/// content. With the content sized by its lines, a tall window ended in an
/// empty band under it; it now takes the height the fields leave.
const _config = [
  GenericEditorSection(
    title: null,
    fields: [
      GenericEditorField(key: 'name', label: 'Name'),
      GenericEditorField(
        key: 'role',
        label: 'Role',
        type: 'select',
        options: [
          {'label': 'System', 'value': 'system'},
          {'label': 'User', 'value': 'user'},
        ],
      ),
      GenericEditorField(key: 'enabled', label: 'Enabled', type: 'switch'),
      GenericEditorField(
        key: 'content',
        label: 'Content',
        type: 'textarea',
        rows: 5,
        expandable: true,
      ),
    ],
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  required double height,
  String content = 'short',
  bool desktop = true,
}) async {
  await tester.binding.setSurfaceSize(Size(620, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: DesktopScope(
            isDesktop: desktop,
            child: DetachedShellHost(
              hasChrome: true,
              child: GenericEditor(
                item: {
                  'name': 'Block',
                  'role': 'system',
                  'enabled': true,
                  'content': content,
                },
                config: _config,
                fillField: 'content',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _content => find.byType(TextField).last;

void main() {
  testWidgets('the content takes the height the other fields leave', (
    tester,
  ) async {
    await _pump(tester, height: 900);

    final field = tester.getRect(_content);
    // Reaches down to the bottom margin instead of stopping after its lines.
    expect(field.bottom, greaterThan(900 - 80));
    expect(field.height, greaterThan(400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('it follows the window as it grows', (tester) async {
    await _pump(tester, height: 600);
    final short = tester.getRect(_content).height;

    await _pump(tester, height: 900);
    final tall = tester.getRect(_content).height;

    expect(tall - short, moreOrLessEquals(300, epsilon: 1));
  });

  testWidgets('a long text makes the editor scroll instead of clipping', (
    tester,
  ) async {
    await _pump(
      tester,
      height: 500,
      content: List.generate(80, (i) => 'line $i').join('\n'),
    );

    expect(tester.takeException(), isNull);
    final scroll = find.byType(SingleChildScrollView);
    expect(scroll, findsOneWidget);
    // The content is taller than the window, so the editor scrolls as a whole.
    expect(tester.getRect(_content).height, greaterThan(500));
  });

  testWidgets('on a phone the content keeps its line-based height', (
    tester,
  ) async {
    await _pump(tester, height: 900, desktop: false);

    expect(tester.getRect(_content).height, lessThan(300));
    expect(find.byType(ListView), findsOneWidget);
  });
}
