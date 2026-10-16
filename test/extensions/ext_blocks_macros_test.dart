import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/services/block_request_macros.dart';
import 'package:glaze_flutter/features/extensions/services/info_block_injector.dart';

class _Reader implements InfoBlockReader {
  _Reader(this.rows);

  final Map<String, List<InfoBlock>> rows;

  @override
  Future<List<InfoBlock>> getByMessageId(
    String sessionId,
    String messageId, {
    int swipeId = 0,
  }) async => rows[messageId] ?? const [];
}

InfoBlock _row(
  String blockId,
  String messageId,
  String content, {
  BlockRunStatus status = BlockRunStatus.done,
}) => InfoBlock(
  id: '$blockId-$messageId',
  sessionId: 's',
  messageId: messageId,
  blockId: blockId,
  blockName: blockId,
  blockType: 'generated',
  content: content,
  createdAt: 0,
  status: status,
);

void main() {
  group('{{ExtBlocks::name}}', () {
    test('stands for the block, its alias too, and is empty when unknown', () {
      const blocks = {'stats': '<stats>\ngold: 3\n</stats>'};
      expect(
        replaceExtBlocksMacros(
          'A {{ExtBlocks::stats}} B {{extblocks-getblockbyname:: stats }} '
          'C {{ExtBlocks::nope}}',
          blocks,
        ),
        'A <stats>\ngold: 3\n</stats> B <stats>\ngold: 3\n</stats> C ',
      );
      expect(
        replaceExtBlocksMacros('{{ExtBlocks-Call::stats}}', blocks),
        '{{ExtBlocks-Call::stats}}',
      );
    });

    test('runs in the main macro engine before the other macros', () {
      final out = replaceMacros(
        'State: {{ExtBlocks::mood}}',
        const MacroContext(
          charName: 'Bo',
          charId: 'c',
          sessionId: 's',
          userName: 'Ann',
          extBlocks: {'mood': '<mood>{{user}} is calm</mood>'},
        ),
      ).text;
      expect(out, 'State: <mood>Ann is calm</mood>');
    });

    test('macro blocks fill the macro and are not placed in the prompt', () {
      final result = buildPrompt(
        PromptPayload(
          character: Character(id: 'c1', name: 'Alice'),
          preset: const Preset(
            id: 'p1',
            name: 'Prompt',
            blocks: [
              PresetBlock(
                id: 'main',
                name: 'Main',
                role: 'system',
                content: 'Main. {{ExtBlocks::mood}}',
              ),
              PresetBlock(
                id: 'chat_history',
                name: 'History',
                role: 'system',
                content: '',
              ),
            ],
          ),
          history: const [ChatMessage(id: 'm1', role: 'user', content: 'Hi')],
          apiConfig: const ApiConfig(
            id: 'api',
            name: 'API',
            contextSize: 10000,
            maxTokens: 100,
          ),
          runtimePromptBlocks: const [
            RuntimePromptBlock(
              id: 'mood',
              content: '<mood>calm</mood>',
              depth: 0,
              role: 'system',
              placement: RuntimePromptPlacement.macro,
            ),
          ],
        ),
      );
      final contents = result.messages.map((m) => m.content).toList();
      expect(contents, contains('Main. <mood>calm</mood>'));
      expect(
        contents.where((c) => c.contains('<mood>calm</mood>')),
        hasLength(1),
      );
    });

    test('the injector gives each block its latest finished state', () async {
      const messages = [
        ChatMessage(id: 'a1', role: 'assistant', content: 'one'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'two'),
      ];
      final injector = InfoBlockInjector(
        _Reader({
          'a1': [_row('mood', 'a1', 'old'), _row('stats', 'a1', 'gold: 1')],
          'a2': [
            _row('mood', 'a2', 'new'),
            _row('stats', 'a2', 'gold: 9', status: BlockRunStatus.error),
          ],
        }),
      );
      final blocks = await injector.buildMacroBlocks(
        messages: messages,
        sessionId: 's',
        preset: const ExtensionPreset(
          id: 'p',
          name: 'p',
          blocks: [
            BlockConfig(id: 'mood', name: 'mood'),
            BlockConfig(
              id: 'stats',
              name: 'stats',
              type: BlockType.accumulation,
            ),
            BlockConfig(id: 'off', name: 'off', enabled: false),
          ],
        ),
      );
      expect(
        blocks.every((b) => b.placement == RuntimePromptPlacement.macro),
        isTrue,
      );
      expect(extBlocksMacroValues(blocks), {
        'mood': '<mood>\nnew\n</mood>',
        'stats': '<stats>\ngold: 1\n</stats>',
      });
    });

    test('a macro placement survives the isolate round trip', () {
      const block = RuntimePromptBlock(
        id: 'mood',
        content: 'x',
        depth: 0,
        role: 'system',
        placement: RuntimePromptPlacement.macro,
      );
      expect(
        RuntimePromptBlock.fromJson(block.toJson()).placement,
        RuntimePromptPlacement.macro,
      );
      final ctx = MacroContext.fromJson(
        const MacroContext(
          charName: 'c',
          charId: 'c',
          sessionId: 's',
          extBlocks: {'a': 'b'},
        ).toJson(),
      );
      expect(ctx.extBlocks, {'a': 'b'});
    });
  });

  group('block request macros', () {
    test('world info and the main prompt fill the request', () {
      final out = applyBlockRequestMacros(
        [
          {'role': 'system', 'content': '{{mainPrompt}}\n{{WIBEFORE}}'},
          {'role': 'user', 'content': '{{wiAfter}}|{{wiAll}}|{{wiDepth}}'},
        ],
        worldInfo: (before: 'B', after: 'A', examples: '', depth: ''),
        mainPrompt: 'Main',
      );
      expect(out[0], {'role': 'system', 'content': 'Main\nB'});
      expect(out[1]['content'], 'A|B\n\nA|');
    });

    test('only what is asked for is read', () {
      const plain = [
        {'role': 'user', 'content': 'nothing here'},
      ];
      expect(requestNeedsWorldInfo(plain), isFalse);
      expect(requestNeedsMainPrompt(plain), isFalse);
      expect(
        requestNeedsWorldInfo([
          {'role': 'user', 'content': 'x {{wiall}}'},
        ]),
        isTrue,
      );
      expect(applyBlockRequestMacros(plain), same(plain));
    });
  });
}
