import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/services/upstream_block_codec.dart';

/// The six block types collapsed onto four, and the two that disappeared
/// became settings of a generated block. A preset stored under the old model
/// has to come back meaning the same thing, because presets live in the
/// database and nobody is going to re-author them.
void main() {
  BlockConfig decode(Map<String, dynamic> json) =>
      BlockConfig.fromJson({'id': 'b1', 'name': 'Block', ...json});

  group('legacy block types', () {
    test('infoblock becomes a generated card', () {
      final block = decode({'type': 'infoblock', 'prompt': 'Describe the room'});

      expect(block.type, BlockType.generated);
      expect(block.render, BlockRender.card);
      expect(block.prompt, 'Describe the room');
    });

    test('imageGen becomes a generated block that keeps its own prompt', () {
      final block = decode({
        'type': 'imageGen',
        'prompt': 'Write an <image_prompt> card',
      });

      expect(block.type, BlockType.generated);
      expect(block.render, BlockRender.card);
      expect(block.prompt, 'Write an <image_prompt> card');
    });

    test('a prompt-less imageGen keeps the instruction the runtime gave it', () {
      // The old runtime hard-coded this for the image type; with the type gone
      // the block would otherwise come back with nothing to ask the model.
      final block = decode({'type': 'imageGen'});

      expect(block.type, BlockType.generated);
      expect(block.prompt, legacyImageAgentPrompt);
    });

    test('imageGen falls back to its own legacy instruction field', () {
      final block = decode({
        'type': 'imageGen',
        'imagePromptInstruction': 'Draw the scene',
      });

      expect(block.prompt, 'Draw the scene');
    });

    test('an image or JS block never reads its reply out of a template', () {
      // Both skipped template extraction outright, so a template left on one
      // from before that rule must not start being honoured now.
      for (final type in const ['imageGen', 'jsRunner']) {
        final block = decode({'type': type, 'template': '<x>\n\n</x>'});
        expect(block.template, isEmpty, reason: type);
      }
    });

    test('interactive becomes a generated block rendered as a panel', () {
      final block = decode({
        'type': 'interactive',
        'script': '<div>hello</div>',
      });

      expect(block.type, BlockType.generated);
      expect(block.render, BlockRender.panel);
      // Its markup shared the `script` field with the JS runner's code.
      expect(block.staticContent, '<div>hello</div>');
      expect(block.script, isEmpty);
    });

    test('an LLM-driven interactive block keeps its prompt, not a body', () {
      final block = decode({'type': 'interactive', 'prompt': 'Build a panel'});

      expect(block.type, BlockType.generated);
      expect(block.render, BlockRender.panel);
      expect(block.prompt, 'Build a panel');
      expect(block.staticContent, isEmpty);
    });

    test('jsRunner becomes a script block and keeps its code', () {
      final block = decode({'type': 'jsRunner', 'script': 'return 1;'});

      expect(block.type, BlockType.script);
      expect(block.script, 'return 1;');
    });

    test('a preset migrates every block it carries', () {
      final preset = ExtensionPreset.fromJson({
        'id': 'p1',
        'name': 'Preset',
        'blocks': [
          {'id': 'a', 'name': 'Card', 'type': 'infoblock'},
          {'id': 'b', 'name': 'Panel', 'type': 'interactive'},
          {'id': 'c', 'name': 'Code', 'type': 'jsRunner'},
        ],
      });

      expect(
        preset.blocks.map((BlockConfig b) => b.type).toList(),
        [BlockType.generated, BlockType.generated, BlockType.script],
      );
      expect(preset.blocks[1].render, BlockRender.panel);
    });

    test('a block already on the new model is left alone', () {
      final block = decode({
        'type': 'generated',
        'render': 'panel',
        'template': '<x>\n\n</x>',
        'staticContent': '<p>hi</p>',
      });

      expect(block.type, BlockType.generated);
      expect(block.render, BlockRender.panel);
      expect(block.template, '<x>\n\n</x>');
      expect(block.staticContent, '<p>hi</p>');
    });
  });

  group('defaults', () {
    test('a new block is a generated card', () {
      const block = BlockConfig(id: 'b1', name: 'Block');

      expect(block.type, BlockType.generated);
      expect(block.render, BlockRender.card);
      expect(block.type.isRunnable, isTrue);
    });

    test('rewrite and accumulation still have no runtime', () {
      expect(BlockType.rewrite.isRunnable, isFalse);
      expect(BlockType.accumulation.isRunnable, isFalse);
      expect(BlockType.script.isRunnable, isTrue);
    });
  });

  group('upstream round trip', () {
    test('generated and script survive both directions unchanged', () {
      for (final type in const ['generated', 'script']) {
        final decoded = decodeUpstreamBlock({
          'id': 'u1',
          'name': 'Upstream',
          'block_type': type,
          'prompt': 'do the thing',
        });
        expect(encodeUpstreamBlock(decoded)['block_type'], type, reason: type);
      }
    });

    test('a panel block still exports as a generated one', () {
      // The original has no render field, so the setting is dropped rather
      // than turned into a type it does not have.
      final block = decode({'type': 'interactive', 'prompt': 'Build a panel'});

      expect(encodeUpstreamBlock(block)['block_type'], 'generated');
    });
  });
}
