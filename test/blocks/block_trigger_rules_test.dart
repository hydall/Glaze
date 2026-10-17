import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_processor.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_trigger_rules.dart';

BlockConfig _block({
  BlockTrigger trigger = BlockTrigger.afterAssistant,
  bool onUser = false,
  bool onChar = true,
  int period = 2,
  String keyword = '',
  bool keywordIsRegex = false,
}) => BlockConfig(
  id: 'b',
  name: 'B',
  trigger: trigger,
  triggerOnUser: onUser,
  triggerOnChar: onChar,
  period: period,
  keyword: keyword,
  keywordIsRegex: keywordIsRegex,
);

void main() {
  group('trigger sides', () {
    test('a block may answer to both sides', () {
      final block = _block(onUser: true, onChar: true);
      expect(block.runsOnUser, isTrue);
      expect(block.runsOnChar, isTrue);
    });

    test('a legacy afterUser block runs after the user only', () {
      final block = _block(trigger: BlockTrigger.afterUser);
      expect(block.runsOnUser, isTrue);
      expect(block.runsOnChar, isFalse);
    });

    test('a block with neither switch never runs on its own', () {
      final block = _block(onChar: false);
      expect(block.runsOnUser, isFalse);
      expect(block.runsOnChar, isFalse);
    });

    test('a periodic timer block answers to neither message side', () {
      final block = _block(trigger: BlockTrigger.periodic, onUser: true);
      expect(block.runsOnUser, isFalse);
      expect(block.runsOnChar, isFalse);
      expect(block.runsOn(BlockTrigger.periodic), isTrue);
    });

    test('the processor puts a two-sided block in both chains', () {
      final preset = ExtensionPreset(
        id: 'p',
        name: 'P',
        blocks: [_block(onUser: true, onChar: true)],
      );
      const processor = BlockProcessor();
      expect(
        processor.selectBlocks(preset, BlockTrigger.afterUser),
        hasLength(1),
      );
      expect(
        processor.selectBlocks(preset, BlockTrigger.afterAssistant),
        hasLength(1),
      );
    });
  });

  group('period', () {
    bool met(BlockConfig b, int index, {bool isUser = false}) =>
        blockConditionsMet(
          b,
          messageIndex: index,
          isUser: isUser,
          messageText: '',
        );

    test('period 2 runs on every reply of an alternating chat', () {
      final block = _block();
      // greeting 0, user 1, char 2, user 3, char 4
      expect(met(block, 2), isTrue);
      expect(met(block, 4), isTrue);
      expect(met(block, 1, isUser: true), isTrue);
      expect(met(block, 3, isUser: true), isTrue);
    });

    test('period 4 skips every other turn', () {
      final block = _block(period: 4);
      expect(met(block, 2), isFalse);
      expect(met(block, 4), isTrue);
      expect(met(block, 6), isFalse);
      expect(met(block, 8), isTrue);
      expect(met(block, 1, isUser: true), isTrue);
      expect(met(block, 3, isUser: true), isFalse);
      expect(met(block, 5, isUser: true), isTrue);
    });
  });

  group('keyword', () {
    bool met(BlockConfig b, String text) => blockConditionsMet(
      b,
      messageIndex: 3,
      isUser: false,
      messageText: text,
    );

    test('a keyword replaces the period', () {
      final block = _block(keyword: 'battle');
      expect(met(block, 'a battle begins'), isTrue);
      expect(met(block, 'quiet day'), isFalse);
    });

    test('a plain keyword is matched literally', () {
      final block = _block(keyword: 'a.c');
      expect(met(block, 'abc'), isFalse);
      expect(met(block, 'xa.cx'), isTrue);
    });

    test('a regex keyword honors slash flags', () {
      final block = _block(keyword: '/BATTLE/i', keywordIsRegex: true);
      expect(met(block, 'the battle'), isTrue);
    });

    test('a bare regex keyword is case sensitive', () {
      final block = _block(keyword: 'BATTLE', keywordIsRegex: true);
      expect(met(block, 'the battle'), isFalse);
    });

    test('an invalid regex never matches', () {
      final block = _block(keyword: '(', keywordIsRegex: true);
      expect(met(block, '('), isFalse);
    });
  });

  group('upstreamStringToRegex', () {
    test('an unknown flag drops every flag', () {
      final regex = upstreamStringToRegex('/abc/iz')!;
      expect(regex.isCaseSensitive, isTrue);
    });

    test('the s flag lets a dot cross lines', () {
      expect(upstreamStringToRegex('/a.b/s')!.hasMatch('a\nb'), isTrue);
      expect(upstreamStringToRegex('/a.b/')!.hasMatch('a\nb'), isFalse);
    });
  });
}
