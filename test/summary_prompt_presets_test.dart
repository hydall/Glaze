import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/services/memory_prompt_presets.dart'
    show MemoryPromptPreset;
import 'package:glaze_flutter/core/services/summary_prompt_presets.dart';
import 'package:glaze_flutter/core/state/summary_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SummaryPromptPresets', () {
    const mine = MemoryPromptPreset(
      key: 'mine',
      label: 'Mine',
      prompt: 'Summarize in limerick form.',
    );

    test('an unset template is the built-in default', () {
      expect(
        SummaryPromptPresets.match(null)?.key,
        SummaryPromptPresets.fallbackKey,
      );
      expect(
        SummaryPromptPresets.match('   ')?.key,
        SummaryPromptPresets.fallbackKey,
      );
      // Which is the prompt the service actually falls back to.
      expect(SummaryPromptPresets.builtIn.first.prompt, defaultSummaryPrompt);
    });

    test('a stored template is recognised as the preset it came from', () {
      final preset = SummaryPromptPresets.builtIn[1];
      expect(SummaryPromptPresets.match(preset.prompt)?.key, preset.key);
      // Whitespace around it does not make it something else.
      expect(
        SummaryPromptPresets.match('\n${preset.prompt}\n')?.key,
        preset.key,
      );
    });

    test('an edited template belongs to no preset', () {
      final edited = '${SummaryPromptPresets.builtIn[1].prompt}\nAlso rhyme.';
      expect(SummaryPromptPresets.match(edited), isNull);
    });

    test('a saved prompt of your own counts too', () {
      expect(SummaryPromptPresets.match(mine.prompt), isNull);
      expect(SummaryPromptPresets.match(mine.prompt, [mine])?.key, 'mine');
      expect(SummaryPromptPresets.all([mine]).last.key, 'mine');
    });

    test('every built-in leaves the transcript and the old summary alone', () {
      // They rely on the service placing both, so a preset must not carry a
      // placeholder that would resolve to an empty label on the first run.
      for (final preset in SummaryPromptPresets.builtIn.skip(1)) {
        expect(preset.prompt, isNot(contains(summaryPreviousPlaceholder)));
        expect(preset.prompt, isNot(contains(summaryHistoryPlaceholder)));
      }
    });
  });

  group('custom summary prompts', () {
    const mine = MemoryPromptPreset(
      key: 'mine',
      label: 'Mine',
      prompt: 'Summarize in limerick form.',
    );

    ProviderContainer container() {
      final result = ProviderContainer();
      addTearDown(result.dispose);
      return result;
    }

    test('start empty and survive a round trip', () async {
      SharedPreferences.setMockInitialValues({});
      final c = container();

      expect(await c.read(summaryCustomPromptsProvider.future), isEmpty);
      await c.read(summaryCustomPromptsProvider.notifier).save([mine]);
      expect(c.read(summaryCustomPromptsProvider).value?.single.key, 'mine');

      // A second container reads what the first one wrote.
      final reopened = container();
      final restored = await reopened.read(summaryCustomPromptsProvider.future);
      expect(restored.single.prompt, mine.prompt);
    });

    test('an unreadable stored value is ignored, not fatal', () async {
      SharedPreferences.setMockInitialValues({
        SummaryCustomPromptsNotifier.prefsKey: 'not json at all',
      });
      final c = container();

      expect(await c.read(summaryCustomPromptsProvider.future), isEmpty);
    });
  });
}
