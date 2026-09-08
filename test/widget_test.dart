import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:glaze_flutter/app.dart';
import 'package:glaze_flutter/core/db/app_db.dart';

import 'helpers/pump_glaze_app.dart';
import 'helpers/test_container.dart';

void main() {
  setUpAll(initLocalizationOnce);

  testWidgets('App renders without crashing', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = makeContainer(db);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          child: const GlazeApp(skipStartup: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(MaterialApp), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await tester.pump();
  });
}
