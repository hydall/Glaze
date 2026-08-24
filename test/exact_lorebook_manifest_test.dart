import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'dart:convert';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  ExactLorebookManifestEntry entry(int index, {String book = 'book'}) =>
      ExactLorebookManifestEntry.fromMergedEntry(
        entry: LorebookEntry(
          id: 'entry-$index',
          lorebookId: book,
          lorebookName: 'Lorebook',
          comment: 'Entry $index',
          content: 'raw {{user}} $index',
          position: 'worldInfoBefore',
          order: index,
        ),
        source: 'keyword',
        classification: 'worldInfoBefore',
        injectionIndex: index,
        renderedContent: 'raw Ada $index',
      );
  ExactLorebookManifest manifest() => ExactLorebookManifest(
    entries: [entry(1), entry(0)],
    promptProvenance: const ExactLorebookPromptProvenance(
      characterId: 'character',
      presetSnapshotHash: 'preset-hash',
    ),
    providerMessagesHash: 'provider-hash',
  );

  test('retains full merged entry snapshot and sorted injection order', () {
    final value = manifest();
    expect(value.entries.map((value) => value.entryId), ['entry-0', 'entry-1']);
    expect(value.entries.first.entry.lorebookName, 'Lorebook');
    expect(
      value.entries.first.rawContentHash,
      isNot(value.entries.first.renderedContentHash),
    );
  });

  test('durable roundtrip is canonical and hash verified', () {
    final value = manifest();
    final restored = ExactLorebookManifest.decodeDurable(value.toJson());
    expect(restored.canonicalJson, value.canonicalJson);
    expect(restored.canonicalHash, value.canonicalHash);
  });

  test('durable decoder fails closed for malformed contract fields', () {
    final valid = Map<String, dynamic>.from(manifest().toJson());
    final missingHash = Map<String, dynamic>.from(valid)
      ..remove('canonicalHash');
    expect(
      () => ExactLorebookManifest.decodeDurable(missingHash),
      throwsFormatException,
    );
    final invalidSource = Map<String, dynamic>.from(valid)
      ..['entries'] = [
        {
          ...(valid['entries'] as List).first as Map<String, dynamic>,
          'source': 'unknown',
        },
        (valid['entries'] as List)[1],
      ];
    expect(
      () => ExactLorebookManifest.decodeDurable(invalidSource),
      throwsFormatException,
    );
    final legacyVersion = Map<String, dynamic>.from(valid)
      ..['schemaVersion'] = 0;
    expect(
      () => ExactLorebookManifest.decodeDurable(legacyVersion),
      throwsFormatException,
    );
  });

  test('only explicitly reported entries reach the manifest', () {
    final value = manifest();
    final confirmed = value.confirmedBy([
      ExactLorebookInjectionReport(
        namespacedId: value.entries.first.namespacedId,
        placement: 0,
        renderedContent: value.entries.first.renderedContent,
      ),
    ]);

    expect(confirmed.entries, hasLength(1));
    expect(confirmed.entries.single.entryId, 'entry-0');
  });

  test('Studio classification confirmation retains only emitted slots', () {
    final value = ExactLorebookManifest(
      entries: [
        entry(0),
        ExactLorebookManifestEntry.fromMergedEntry(
          entry: const LorebookEntry(
            id: 'macro',
            lorebookId: 'book',
            content: 'macro lore',
            position: 'lorebooksMacro',
          ),
          source: 'vector',
          classification: 'lorebooksMacro',
          injectionIndex: 1,
          renderedContent: 'macro lore',
        ),
      ],
      promptProvenance: const ExactLorebookPromptProvenance(
        characterId: 'character',
        presetSnapshotHash: 'preset-hash',
      ),
      providerMessagesHash: 'provider-hash',
    );

    final confirmed = value.confirmedForClassifications({'lorebooksMacro'});

    expect(confirmed.entries, hasLength(1));
    expect(confirmed.entries.single.entryId, 'macro');
    expect(confirmed.entries.single.injectionIndex, 0);
  });

  test('empty explicit report does not retain an entry', () {
    final value = manifest();
    final confirmed = value.confirmedBy([
      ExactLorebookInjectionReport(
        namespacedId: value.entries.first.namespacedId,
        placement: 0,
        renderedContent: '',
      ),
    ]);

    expect(confirmed.entries, isEmpty);
  });

  test('reported regex output becomes rendered content and hash', () {
    final value = manifest();
    final confirmed = value.confirmedBy([
      ExactLorebookInjectionReport(
        namespacedId: value.entries.first.namespacedId,
        placement: 0,
        renderedContent: 'regex transformed',
      ),
    ]);

    expect(confirmed.entries.single.renderedContent, 'regex transformed');
    expect(
      confirmed.entries.single.renderedContentHash,
      isNot(value.entries.first.renderedContentHash),
    );
  });

  test('PromptResult runtime transport remains compatible', () {
    final original = PromptResult(
      messages: const [],
      breakdown: const TokenBreakdown(
        sourceTokens: {},
        staticTotal: 0,
        historyBudget: 0,
        historyTokens: 0,
        totalTokens: 0,
        cutoffIndex: 0,
        trimmedHistory: [],
      ),
      sessionVars: const {},
      globalVars: const {},
      exactLorebookManifest: manifest(),
    );
    expect(
      PromptResult.fromJson(
        original.toJson(),
      ).exactLorebookManifest?.canonicalHash,
      manifest().canonicalHash,
    );
  });

  test('records lore injected through every character-field placeholder', () {
    for (final fixture in [
      ('charScenario', '{{scenario}}'),
      ('charPersonality', '{{personality}}'),
      ('charDescription', '{{description}}'),
    ]) {
      final result = buildPrompt(
        PromptPayload(
          character: const Character(
            id: 'character',
            name: 'Character',
            scenario: 'base scenario',
            personality: 'base personality',
            description: 'base description',
          ),
          preset: Preset(
            id: 'preset',
            name: 'Preset',
            blocks: [
              PresetBlock(
                id: 'custom',
                name: 'Custom',
                role: 'system',
                content: fixture.$2,
              ),
            ],
          ),
          history: const [],
          apiConfig: const ApiConfig(id: 'api'),
          lorebooks: [
            Lorebook(
              id: 'book',
              name: 'Book',
              entries: [
                LorebookEntry(
                  id: fixture.$1,
                  constant: true,
                  content: 'LORE_${fixture.$1}',
                  position: fixture.$1,
                ),
              ],
            ),
          ],
        ),
      );
      final manifest = result.exactLorebookManifest!;
      expect(manifest.entries.single.classification, fixture.$1);
      expect(manifest.entries.single.renderedContent, 'LORE_${fixture.$1}');
      expect(result.messages.single.content, contains('LORE_${fixture.$1}'));
    }
  });

  test(
    'manifest tracks final concatenated lore transform and API transport hash',
    () {
      final result = buildPrompt(
        PromptPayload(
          character: const Character(id: 'character', name: 'Character'),
          preset: const Preset(
            id: 'preset',
            name: 'Preset',
            regexes: [
              PresetRegex(
                id: 'regex',
                name: 'Transform lore',
                regex: 'LORE',
                replacement: 'FINAL',
                placement: [4],
                ephemerality: [2],
              ),
            ],
            blocks: [
              PresetBlock(
                id: 'custom',
                name: 'Custom',
                role: 'system',
                content: '{{lorebooks}}',
              ),
            ],
          ),
          history: const [],
          apiConfig: const ApiConfig(id: 'api'),
          lorebooks: [
            Lorebook(
              id: 'book',
              name: 'Book',
              entries: [
                LorebookEntry(
                  id: 'entry',
                  constant: true,
                  content: 'LORE',
                  position: 'lorebooksMacro',
                ),
              ],
            ),
          ],
        ),
      );
      final manifest = result.exactLorebookManifest!;
      expect(manifest.entries.single.renderedContent, 'FINAL');
      expect(
        manifest.providerMessagesHash,
        computeHash(jsonEncode(buildApiMessages(result.messages))),
      );
    },
  );

  for (final mode in ['append', 'depth']) {
    test('records every lore placeholder emitted through $mode blocks', () {
      for (final fixture in [
        ('lorebooksMacro', '{{lorebooks}}'),
        ('charScenario', '{{scenario}}'),
        ('charPersonality', '{{personality}}'),
        ('charDescription', '{{description}}'),
      ]) {
        final result = buildPrompt(
          PromptPayload(
            character: const Character(
              id: 'character',
              name: 'Character',
              scenario: 'scenario',
              personality: 'personality',
              description: 'description',
            ),
            preset: Preset(
              id: 'preset',
              name: 'Preset',
              blocks: [
                PresetBlock(
                  id: 'target',
                  name: 'Target',
                  role: 'system',
                  content: fixture.$2,
                  appendToLastMessage: mode == 'append',
                  insertionMode: mode == 'depth' ? 'depth' : 'relative',
                  depth: mode == 'depth' ? 0 : null,
                ),
                const PresetBlock(
                  id: 'chat_history',
                  name: 'History',
                  role: 'system',
                  content: '',
                ),
              ],
            ),
            history: const [
              ChatMessage(id: 'user', role: 'user', content: 'Hello'),
            ],
            apiConfig: const ApiConfig(id: 'api'),
            lorebooks: [
              Lorebook(
                id: 'book',
                name: 'Book',
                entries: [
                  LorebookEntry(
                    id: fixture.$1,
                    constant: true,
                    content: 'LORE_${fixture.$1}',
                    position: fixture.$1,
                  ),
                ],
              ),
            ],
          ),
        );
        final manifest = result.exactLorebookManifest!;
        expect(manifest.entries, hasLength(1), reason: '$mode ${fixture.$1}');
        expect(manifest.entries.single.classification, fixture.$1);
        expect(manifest.entries.single.renderedContent, 'LORE_${fixture.$1}');
      }
    });
  }
}
