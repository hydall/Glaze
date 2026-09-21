import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/pump_localized.dart';

/// The stepped-trim toast is built with `.plural`, which reads the loaded
/// locale — a bare `.tr` on the plural map would render nothing. This file runs
/// in the Russian locale only: `pumpLocalized` binds the locale globally, so a
/// second locale in the same file reads the first one's leftovers.
void main() {
  Widget probe(int dropped, int tokens) => Builder(
    builder: (_) => Text(
      'history_trim_toast'.plural(dropped, namedArgs: {'tokens': '$tokens'}),
    ),
  );

  testWidgets('Russian uses the plural form for several messages', (
    tester,
  ) async {
    await pumpLocalized(tester, probe(5, 1230));
    expect(
      find.text('История обрезана: 5 сообщений (1230 токенов)'),
      findsOneWidget,
    );
  });

  testWidgets('Russian uses the one form for a single message', (tester) async {
    await pumpLocalized(tester, probe(1, 40));
    expect(
      find.text('История обрезана: 1 сообщение (40 токенов)'),
      findsOneWidget,
    );
  });
}
