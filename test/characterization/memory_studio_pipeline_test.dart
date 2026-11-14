import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/prompt_block_router.dart';

void main() {
  group('PromptBlockRouter (Phase 11)', () {
    test('classifies memory blocks correctly', () {
      expect(PromptBlockRouter.classifyBlock('Memory Context'), 'memory');
      expect(PromptBlockRouter.classifyBlock('Memory Recall'), 'memory');
    });

    test('classifies continuity blocks correctly', () {
      expect(PromptBlockRouter.classifyBlock('Continuity Check'), 'continuity');
      expect(PromptBlockRouter.classifyBlock('Relationship State'), 'continuity');
      expect(PromptBlockRouter.classifyBlock('Tracker'), 'continuity');
    });

    test('classifies scenario blocks correctly', () {
      expect(PromptBlockRouter.classifyBlock('Scenario Planning'), 'scenario');
      expect(PromptBlockRouter.classifyBlock('Arc Progression'), 'scenario');
      expect(PromptBlockRouter.classifyBlock('Quest Tracker'), 'scenario');
    });

    test('classifies director blocks correctly', () {
      expect(PromptBlockRouter.classifyBlock('Director Notes'), 'director');
      expect(PromptBlockRouter.classifyBlock('Tone and Pacing'), 'director');
    });

    test('classifies style blocks correctly', () {
      expect(PromptBlockRouter.classifyBlock('Writing Style'), 'style');
      expect(PromptBlockRouter.classifyBlock('Prose Guidelines'), 'style');
    });

    test('classifies intimacy/violence blocks correctly', () {
      expect(PromptBlockRouter.classifyBlock('Intimacy Rules'), 'intimacy');
      expect(PromptBlockRouter.classifyBlock('Violence Guidelines'), 'violence');
    });

    test('classifies utility/OOC blocks correctly', () {
      expect(PromptBlockRouter.classifyBlock('Utility Commands'), 'utility');
      expect(PromptBlockRouter.classifyBlock('OOC Instructions'), 'utility');
    });

    test('defaults to final for unrecognized blocks', () {
      expect(PromptBlockRouter.classifyBlock('Some Random Block'), 'final');
    });

    test('filterForStage returns only matching shards', () {
      final blocks = [
        PresetBlockInfo.classify('Memory Context', 'memory content'),
        PresetBlockInfo.classify('Writing Style', 'style content'),
        PresetBlockInfo.classify('Director Notes', 'director content'),
        PresetBlockInfo.classify('OOC', 'utility content'),
      ];

      final curatorShards = PromptBlockRouter.filterForStage(
        StudioStage.memoryCurator,
        blocks,
      );
      expect(curatorShards, hasLength(1));
      expect(curatorShards.first.shard, 'memory');

      final directorShards = PromptBlockRouter.filterForStage(
        StudioStage.director,
        blocks,
      );
      // Director stage gets {'director', 'style', 'continuity'} shards
      expect(directorShards, hasLength(2));
      expect(directorShards.any((s) => s.shard == 'director'), isTrue);
      expect(directorShards.any((s) => s.shard == 'style'), isTrue);

      final responderShards = PromptBlockRouter.filterForStage(
        StudioStage.mainResponder,
        blocks,
      );
      expect(responderShards.any((s) => s.shard == 'style'), isTrue);
      expect(responderShards.any((s) => s.shard == 'utility'), isTrue);
      expect(responderShards.any((s) => s.shard == 'memory'), isFalse);
    });
  });
}
