import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

/// Pumps one widget with real localization loaded, in the app's own theme.
///
/// Most widget tests here run without `EasyLocalization`, which makes `.tr()`
/// return the key — convenient for asserting on labels. `.plural()` is not so
/// forgiving: it reads the loaded locale and throws a `LateError` when there
/// isn't one. Anything using it needs this.
///
/// The pump runs inside [WidgetTester.runAsync] so `rootBundle` can actually
/// deliver the translation assets; without it the load future never completes.
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('ru'),
  List<Override> overrides = const [],
  Size surfaceSize = const Size(412, 900),
}) async {
  SharedPreferences.setMockInitialValues({});
  await EasyLocalization.ensureInitialized();
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          startLocale: locale,
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: AppTheme.dark(
                const ThemePreset(id: 'default', name: 'Default'),
              ),
              home: Scaffold(body: child),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 4; i++) {
      await tester.pump(Duration.zero);
    }
    await tester.pump(const Duration(milliseconds: 400));
  });
}
