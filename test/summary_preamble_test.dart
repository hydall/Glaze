import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/services/summary_preamble.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';

/// The instruction a reader puts in front of every summary prompt for a model
/// that refuses, and how a refusal is told from a summary. See
/// `docs/INVARIANTS.md` INV-S5.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SummaryPreamble', () {
    test('is off by default, with the default text ready', () {
      const preamble = SummaryPreamble();
      expect(preamble.enabled, isFalse);
      expect(preamble.active, isFalse);
      expect(preamble.text, SummaryPreamble.defaultText);
      expect(preamble.apply('Summarize.'), 'Summarize.');
    });

    test('goes in front of the prompt when on', () {
      const preamble = SummaryPreamble(enabled: true, text: ' Retell it. ');
      expect(preamble.apply('\nSummarize.'), 'Retell it.\n\nSummarize.');
    });

    test('an emptied text puts nothing in front', () {
      const preamble = SummaryPreamble(enabled: true, text: '  ');
      expect(preamble.active, isFalse);
      expect(preamble.apply('Summarize.'), 'Summarize.');
    });

    test('survives a round trip, text and all', () {
      const preamble = SummaryPreamble(enabled: true, text: 'Retell it.');
      expect(SummaryPreamble.fromJson(preamble.toJson()), preamble);
      // A stored switch without a text falls back to the default text.
      expect(
        SummaryPreamble.fromJson(const {'enabled': true}),
        const SummaryPreamble(enabled: true),
      );
    });

    test('is stored in the prefs and read back by a new container', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(
        await c.read(summaryPreambleProvider.future),
        isA<SummaryPreamble>().having((p) => p.enabled, 'enabled', isFalse),
      );
      await c
          .read(summaryPreambleProvider.notifier)
          .save(const SummaryPreamble(enabled: true, text: 'Retell it.'));

      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      expect(
        await reopened.read(summaryPreambleProvider.future),
        const SummaryPreamble(enabled: true, text: 'Retell it.'),
      );
    });

    test('an unreadable stored value is the default, not fatal', () async {
      SharedPreferences.setMockInitialValues({
        SummaryPreambleNotifier.prefsKey: 'not json',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(
        await c.read(summaryPreambleProvider.future),
        const SummaryPreamble(),
      );
    });
  });
}
