import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs.dart';
import 'package:glaze_flutter/core/llm/prompt_isolate.dart';
import 'package:glaze_flutter/core/llm/prompt_worker.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/preset.dart';

// Baseline command: flutter test test/prompt_lorebook_baseline_test.dart
void main() {
  test('baseline: isolate prompt build handles long history and large lorebook',
      () async {
    const historyCount = 160;
    const lorebookEntryCount = 240;
    const injectedLorebookEntries = 6;
    final inputs = _baselineInputs();

    // The first request includes worker/isolate initialization; the second
    // measures the persistent worker path. Timings are diagnostic only.
    final coldWatch = Stopwatch()..start();
    final cold = await buildFromInputsInIsolate(inputs);
    coldWatch.stop();

    final warmWatch = Stopwatch()..start();
    final warm = await buildFromInputsInIsolate(inputs);
    warmWatch.stop();

    addTearDown(() async {
      final worker = await PromptWorker.ensureInitialized();
      worker.dispose();
    });

    final outputChars = cold.messages.fold<int>(
      0,
      (total, message) => total + message.content.length,
    );
    // ignore: avoid_print
    print(
      'prompt/lorebook baseline: history=$historyCount '
      'lorebookEntries=$lorebookEntryCount cold=${coldWatch.elapsedMilliseconds}ms '
      'warm=${warmWatch.elapsedMilliseconds}ms outputChars=$outputChars '
      'tokens=${cold.breakdown.totalTokens}',
    );

    final expectedLoreIds = [
      for (var index = 0; index < injectedLorebookEntries; index++)
        'lore-$index',
    ];
    expect(cold.triggeredLorebooks.map((entry) => entry.id), expectedLoreIds);
    expect(
      cold.messages.where((message) => message.isHistory).length,
      historyCount,
    );
    expect(
      cold.messages.map((message) => message.content).join('\n'),
      allOf(contains('LOREBOOK_BASELINE_0'), contains('history-marker-159')),
    );

    // Assert output semantics, never a machine-dependent timing threshold.
    expect(_signature(warm), _signature(cold));
    expect(warm.breakdown.totalTokens, cold.breakdown.totalTokens);
  });
}

PromptInputs _baselineInputs() {
  const filler = 'synthetic history payload for deterministic prompt benchmarking ';
  return PromptInputs(
    character: const Character(
      id: 'baseline-character',
      name: 'Baseline Character',
      description: 'A deterministic benchmark character.',
    ),
    apiConfig: const ApiConfig(
      id: 'baseline-api',
      contextSize: 128000,
      maxTokens: 2048,
    ),
    preset: const Preset(
      id: 'baseline-preset',
      name: 'Baseline preset',
      blocks: [
        PresetBlock(
          id: 'char_card',
          name: 'Character',
          role: 'system',
          content: '{{description}}',
        ),
        PresetBlock(
          id: 'chat_history',
          name: 'History',
          role: 'system',
          content: '',
        ),
      ],
    ),
    history: [
      for (var index = 0; index < 160; index++)
        ChatMessage(
          id: 'history-$index',
          role: index.isEven ? 'user' : 'assistant',
          content:
              'history-marker-$index ${List.filled(4, filler).join()}${index == 159 ? 'benchmark-anchor' : ''}',
        ),
    ],
    lorebooks: [
      Lorebook(
        id: 'baseline-lorebook',
        name: 'Baseline lorebook',
        entries: [
          for (var index = 0; index < 240; index++)
            LorebookEntry(
              id: 'lore-$index',
              comment: 'Benchmark lore $index',
              keys: const ['benchmark-anchor'],
              content:
                  'LOREBOOK_BASELINE_$index ${List.filled(12, 'lore fact ').join()}',
              position: 'worldInfoBefore',
              order: index,
            ),
        ],
      ),
    ],
    lorebookSettings: const LorebookGlobalSettings(
      scanDepth: 160,
      maxInjectedEntries: 6,
      recursiveScan: false,
    ),
    memoryEnabled: false,
  );
}

String _signature(PromptResult result) => [
  for (final message in result.messages)
    '${message.role}|${message.blockId}|${message.sourceMessageId}|${message.content}',
  for (final entry in result.triggeredLorebooks)
    'lore|${entry.id}|${entry.source}|${entry.lorebookId}',
].join('\n');
