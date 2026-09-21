import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/pump_localized.dart';

/// English half of the stepped-trim toast check. Separate file because
/// `pumpLocalized` binds the locale globally — see the Russian file.
void main() {
  Widget probe(int dropped, int tokens) => Builder(
    builder: (_) => Text(
      'history_trim_toast'.plural(dropped, namedArgs: {'tokens': '$tokens'}),
    ),
  );

  testWidgets('English pluralizes the trimmed message count', (tester) async {
    await pumpLocalized(tester, probe(3, 1230), locale: const Locale('en'));
    expect(
      find.text('History trimmed: 3 messages (1230 tokens)'),
      findsOneWidget,
    );
  });

  testWidgets('English uses the singular for one message', (tester) async {
    await pumpLocalized(tester, probe(1, 40), locale: const Locale('en'));
    expect(find.text('History trimmed: 1 message (40 tokens)'), findsOneWidget);
  });
}
