import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_processor.dart';

InfoBlock _result(BlockConfig block, String content) {
  return InfoBlock(
    id: 'result-${block.id}',
    sessionId: 's1',
    messageId: 'm1',
    blockId: block.id,
    blockName: block.name,
    blockType: block.type.name,
    content: content,
    createdAt: 1,
    order: block.order,
  );
}

void main() {
  group('BlockProcessor', () {
    test('selectBlocks filters by trigger, enabled flag, and order', () {
      const processor = BlockProcessor();
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Preset',
        blocks: const [
          BlockConfig(
            id: 'disabled',
            name: 'Disabled',
            enabled: false,
            trigger: BlockTrigger.afterUser,
            order: 0,
          ),
          BlockConfig(
            id: 'second',
            name: 'Second',
            trigger: BlockTrigger.afterUser,
            order: 2,
          ),
          BlockConfig(
            id: 'assistant',
            name: 'Assistant',
            trigger: BlockTrigger.afterAssistant,
            order: 1,
          ),
          BlockConfig(
            id: 'first',
            name: 'First',
            trigger: BlockTrigger.afterUser,
            order: 1,
          ),
        ],
      );

      expect(
        processor
            .selectBlocks(preset, BlockTrigger.afterUser)
            .map((block) => block.id),
        ['first', 'second'],
      );
    });

    test('selectBlocks excludes disabled and manual-only autorun blocks', () {
      const processor = BlockProcessor();
      const preset = ExtensionPreset(
        id: 'p1',
        name: 'Preset',
        blocks: [
          BlockConfig(id: 'disabled', name: 'Disabled', enabled: false),
          BlockConfig(id: 'manual', name: 'Manual', manualOnly: true),
          BlockConfig(
            id: 'after-user',
            name: 'After user',
            trigger: BlockTrigger.afterUser,
          ),
        ],
      );

      expect(
        processor.selectBlocks(preset, BlockTrigger.afterAssistant),
        isEmpty,
      );
    });

    test('passes previous output to dependent block', () async {
      const processor = BlockProcessor();
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Preset',
        blocks: const [
          BlockConfig(
            id: 'first',
            name: 'First',
            trigger: BlockTrigger.afterAssistant,
            order: 1,
          ),
          BlockConfig(
            id: 'second',
            name: 'Second',
            trigger: BlockTrigger.afterAssistant,
            order: 2,
            dependsOnPrevious: true,
          ),
        ],
      );
      final seenPrevious = <String?>[];
      final completed = <String>[];

      await processor.run(
        preset: preset,
        trigger: BlockTrigger.afterAssistant,
        cancelToken: CancelToken(),
        runBlock: ({required blockConfig, required previousOutput}) async {
          seenPrevious.add(previousOutput);
          return _result(blockConfig, 'out-${blockConfig.id}');
        },
        onBlockComplete: (block) => completed.add(block.blockId),
      );

      expect(seenPrevious, [null, 'out-first']);
      expect(completed, ['first', 'second']);
    });

    test('waits for all independent blocks before returning', () async {
      const processor = BlockProcessor();
      final firstCompleter = Completer<InfoBlock?>();
      var returned = false;
      final completed = <String>[];
      final preset = ExtensionPreset(
        id: 'p1',
        name: 'Preset',
        blocks: const [
          BlockConfig(
            id: 'slow',
            name: 'Slow',
            trigger: BlockTrigger.afterAssistant,
            order: 1,
          ),
          BlockConfig(
            id: 'fast-a',
            name: 'Fast A',
            trigger: BlockTrigger.afterAssistant,
            order: 2,
          ),
          BlockConfig(
            id: 'fast-b',
            name: 'Fast B',
            trigger: BlockTrigger.afterAssistant,
            order: 3,
          ),
        ],
      );

      final runFuture = processor
          .run(
            preset: preset,
            trigger: BlockTrigger.afterAssistant,
            cancelToken: CancelToken(),
            runBlock: ({required blockConfig, required previousOutput}) {
              if (blockConfig.id == 'slow') {
                return firstCompleter.future;
              }
              return Future.value(
                _result(blockConfig, 'out-${blockConfig.id}'),
              );
            },
            onBlockComplete: (block) => completed.add(block.blockId),
          )
          .then((_) => returned = true);

      await pumpEventQueue();

      expect(returned, isFalse);
      expect(completed, containsAll(['fast-a', 'fast-b']));
      expect(completed, isNot(contains('slow')));

      firstCompleter.complete(_result(preset.blocks.first, 'out-slow'));
      await runFuture;

      expect(returned, isTrue);
      expect(completed, containsAll(['slow', 'fast-a', 'fast-b']));
    });
  });
}
