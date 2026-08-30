import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio_regex_applicator.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_regex.dart';
import 'package:glaze_flutter/core/state/studio_regex_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const macroContext = MacroContext(
    charName: 'Mira',
    userName: 'Danvi',
    charId: 'char-1',
    sessionId: 'session-1',
  );

  PresetRegex script({
    String id = 'regex-1',
    String regex = 'cat',
    String replacement = 'fox',
    bool disabled = false,
  }) => PresetRegex(
    id: id,
    name: id,
    regex: regex,
    replacement: replacement,
    placement: const [1, 2],
    ephemerality: const [2],
    disabled: disabled,
  );

  test('codec preserves canonical stages and ignores unknown stages', () {
    final decoded = StudioRegex.fromJson({
      'script': script().toJson(),
      'stages': ['ledger', 'unknown', 'final'],
    });

    expect(decoded.stages, {'final', 'ledger'});
    expect(decoded.toJson()['stages'], ['final', 'ledger']);
  });

  test('applies only scripts enabled for the requested Studio stage', () {
    final result = applyStudioRegexesToText(
      text: 'cat',
      stage: 'final',
      entries: [
        StudioRegex(script: script(), stages: const {'final'}),
        StudioRegex(
          script: script(
            id: 'disabled',
            regex: 'fox',
            replacement: 'wolf',
            disabled: true,
          ),
          stages: const {'final'},
        ),
        StudioRegex(
          script: script(id: 'ledger', replacement: 'owl'),
          stages: const {'ledger'},
        ),
      ],
      macroContext: macroContext,
    );

    expect(result, 'fox');
  });

  test(
    'stage selection is an additional filter, not an all-stages condition',
    () {
      final entry = StudioRegex(
        script: script(),
        stages: const {'pregen', 'final'},
      );

      expect(
        applyStudioRegexesToText(
          text: 'cat',
          stage: 'pregen',
          entries: [entry],
          macroContext: macroContext,
        ),
        'fox',
      );
      expect(
        applyStudioRegexesToText(
          text: 'cat',
          stage: 'ledger',
          entries: [entry],
          macroContext: macroContext,
        ),
        'cat',
      );
    },
  );

  test('uses ordinary placement filters for Studio messages', () {
    final entries = [
      StudioRegex(
        script: script(regex: 'cat', replacement: 'changed'),
        stages: const {'final'},
      ),
    ];

    final result = applyStudioRegexes(
      messages: const [
        {'role': 'system', 'content': 'cat'},
        {'role': 'user', 'content': 'cat'},
        {'role': 'assistant', 'content': 'cat'},
      ],
      stages: const {'final'},
      entries: entries,
      macroContext: macroContext,
    );

    expect(result[0]['content'], 'cat');
    expect(result[1]['content'], 'changed');
    expect(result[2]['content'], 'changed');
  });

  test('Studio regex supports macros from the Studio context', () {
    final result = applyStudioRegexesToText(
      text: 'Mira greets Danvi',
      stage: 'pregen',
      entries: [
        StudioRegex(
          script: script(
            regex: r'{{char}} greets {{user}}',
            replacement: 'matched',
          ).copyWith(macroRules: '1'),
          stages: const {'pregen'},
        ),
      ],
      macroContext: macroContext,
    );

    expect(result, 'matched');
  });

  test('Studio regex supports escaped macros without Character models', () {
    final result = applyStudioRegexesToText(
      text: 'Mira+ greets Danvi?',
      stage: 'pregen',
      entries: [
        StudioRegex(
          script: script(
            regex: r'{{char}} greets {{user}}',
            replacement: 'matched',
          ).copyWith(macroRules: '2'),
          stages: const {'pregen'},
        ),
      ],
      macroContext: const MacroContext(
        charName: 'Mira+',
        userName: 'Danvi?',
        charId: 'char-1',
        sessionId: 'session-1',
      ),
    );

    expect(result, 'matched');
  });

  test('provider persists separately with stage selections', () async {
    SharedPreferences.setMockInitialValues({
      'gz_global_regex_scripts': jsonEncode([script(id: 'global').toJson()]),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(await container.read(studioRegexProvider.future), isEmpty);
    final entry = StudioRegex(
      script: script(),
      stages: const {'pregen', 'cleaner'},
    );
    await container.read(studioRegexProvider.notifier).addRegex(entry);

    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(studioRegexStorageKey)!) as List;
    expect(stored.single['stages'], ['pregen', 'cleaner']);
    expect(prefs.getString('gz_global_regex_scripts'), isNotNull);

    final updated = entry.copyWith(stages: const {'ledger'});
    await container.read(studioRegexProvider.notifier).updateRegex(updated);
    expect(container.read(studioRegexProvider).value!.single.stages, {
      'ledger',
    });

    await container
        .read(studioRegexProvider.notifier)
        .removeRegex(entry.script.id);
    expect(container.read(studioRegexProvider).value, isEmpty);
  });
}
