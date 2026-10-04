import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/shell/desktop/desktop_layout_provider.dart';
import 'package:glaze_flutter/shared/widgets/generic_editor.dart';

const _config = [
  GenericEditorSection(
    title: 'Main',
    fields: [
      GenericEditorField(key: 'name', label: 'Name'),
      GenericEditorField(
        key: 'mode',
        label: 'Mode',
        type: 'select',
        options: [
          {'label': 'System', 'value': 'system'},
          {'label': 'User', 'value': 'user'},
        ],
      ),
    ],
  ),
];

Future<Map<String, dynamic>> _pump(
  WidgetTester tester, {
  required Size size,
  required bool desktop,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final latest = <String, dynamic>{};
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: DesktopScope(
            isDesktop: desktop,
            child: GenericEditor(
              item: const {'name': 'Alice', 'mode': 'system'},
              config: _config,
              showAvatar: true,
              onChanged: latest.addAll,
            ),
          ),
        ),
      ),
    ),
  );
  return latest;
}

void main() {
  testWidgets('wide desktop editor puts the avatar beside the fields', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1400, 900), desktop: true);

    final avatar = tester.getRect(find.byType(AspectRatio));
    final field = tester.getRect(find.byType(TextField));
    expect(avatar.width, lessThanOrEqualTo(300));
    expect(field.left, greaterThan(avatar.right));
    // Fields stay at a readable width instead of spanning the window.
    expect(field.width, lessThan(800));
  });

  testWidgets('phone editor keeps the full-width avatar above the fields', (
    tester,
  ) async {
    await _pump(tester, size: const Size(400, 900), desktop: false);

    final avatar = tester.getRect(find.byType(AspectRatio));
    expect(avatar.width, greaterThan(350));
    final field = tester.getRect(find.byType(TextField).first);
    expect(field.top, greaterThan(avatar.bottom));
  });

  testWidgets('a select field opens an anchored dropdown on desktop', (
    tester,
  ) async {
    final latest = await _pump(
      tester,
      size: const Size(1400, 900),
      desktop: true,
    );

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<Object?>), findsNWidgets(2));

    await tester.tap(find.text('User').last);
    await tester.pumpAndSettle();
    expect(latest['mode'], 'user');
    expect(find.text('User'), findsOneWidget);
  });
}
