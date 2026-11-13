import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/import/silly_tavern_preset_parser.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/presets/preset_export.dart';

/// The export is a SillyTavern preset first — identifiers, `prompt_order`,
/// the built-in flags — and comes back into Glaze without loss.
void main() {
  final preset = Preset(
    id: 'p1',
    name: 'Mine',
    author: 'me',
    impersonationPrompt: 'Write as {{user}}.',
    blocks: const [
      PresetBlock(
        id: 'main',
        name: 'Main Prompt',
        role: 'system',
        content: 'Be good.',
      ),
      PresetBlock(
        id: 'char_card',
        name: 'Character Card',
        role: 'system',
        content: '',
        isStatic: true,
      ),
      PresetBlock(
        id: 'custom-1',
        name: 'Style',
        role: 'user',
        content: 'Prose.',
        enabled: false,
      ),
      PresetBlock(
        id: 'custom-2',
        name: 'Reminder',
        role: 'system',
        content: 'Remember.',
        insertionMode: 'depth',
        depth: 2,
        appendToLastMessage: true,
      ),
      PresetBlock(
        id: 'custom-3',
        name: 'Spare',
        role: 'system',
        content: 'Unused.',
        isStashed: true,
      ),
      PresetBlock(
        id: 'summary',
        name: 'Summary',
        role: 'system',
        content: '',
        isStatic: true,
        insertionMode: 'in_place',
        depth: 4,
      ),
      PresetBlock(
        id: 'chat_history',
        name: 'Chat History',
        role: 'system',
        content: '',
        isStatic: true,
      ),
    ],
    createdAt: 1,
  );

  test('writes the identifiers and order SillyTavern reads toggles from', () {
    final json = presetExportJson(preset);
    final prompts = (json['prompts'] as List).cast<Map<String, dynamic>>();
    expect(prompts.map((p) => p['identifier']), [
      'main',
      'charDescription',
      'custom-1',
      'custom-2',
      'custom-3',
      'summary',
      'chatHistory',
    ]);
    final card = prompts[1];
    expect(card['marker'], isTrue);
    expect(card['system_prompt'], isTrue);
    expect(prompts[0]['system_prompt'], isTrue);
    expect(prompts[2]['marker'], isFalse);
    expect(prompts[2]['system_prompt'], isFalse);
    expect(prompts[3]['injection_position'], 1);
    expect(prompts[3]['injection_depth'], 2);
    expect(prompts[2]['injection_position'], 0);
    expect(json['impersonation_prompt'], 'Write as {{user}}.');

    final orders = (json['prompt_order'] as List).cast<Map<String, dynamic>>();
    expect(orders.map((o) => o['character_id']), [100000, 100001]);
    final order = (orders[1]['order'] as List).cast<Map<String, dynamic>>();
    // The stashed block is in `prompts` but out of the order.
    expect(order.map((o) => o['identifier']), [
      'main',
      'charDescription',
      'custom-1',
      'custom-2',
      'summary',
      'chatHistory',
    ]);
    expect(order.map((o) => o['enabled']), [
      true,
      true,
      false,
      true,
      true,
      true,
    ]);
  });

  test('comes back into Glaze without loss', () {
    final back = parseSillyTavernPreset(presetExportJson(preset), 'Mine.json');
    final byId = {for (final b in back.blocks) b.id: b};
    for (final original in preset.blocks) {
      final b = byId[original.id];
      expect(b, isNotNull, reason: original.id);
      expect(b!.name, original.name, reason: original.id);
      expect(b.role, original.role, reason: original.id);
      expect(b.content, original.content, reason: original.id);
      expect(b.enabled, original.enabled, reason: original.id);
      expect(b.isStashed, original.isStashed, reason: original.id);
      expect(b.insertionMode, original.insertionMode, reason: original.id);
      expect(b.depth, original.depth, reason: original.id);
      expect(
        b.appendToLastMessage,
        original.appendToLastMessage,
        reason: original.id,
      );
    }
    // Live blocks keep their order; the stashed one is parked after them.
    final liveIds = [
      for (final b in back.blocks)
        if (preset.blocks.any((o) => o.id == b.id) && !b.isStashed) b.id,
    ];
    expect(liveIds, [
      'main',
      'char_card',
      'custom-1',
      'custom-2',
      'summary',
      'chat_history',
    ]);
    expect(back.name, 'Mine');
  });

  test('a SillyTavern file without Glaze keys still imports as before', () {
    final back = parseSillyTavernPreset({
      'name': 'Theirs',
      'prompts': [
        {
          'identifier': 'x',
          'name': 'Deep',
          'role': 'system',
          'content': 'Hi',
          'injection_position': 1,
          'injection_depth': 3,
        },
      ],
      'prompt_order': [
        {
          'character_id': 100001,
          'order': [
            {'identifier': 'x', 'enabled': true},
          ],
        },
      ],
    }, 'Theirs.json');
    final deep = back.blocks.firstWhere((b) => b.id == 'x');
    expect(deep.insertionMode, 'depth');
    expect(deep.depth, 3);
    expect(deep.appendToLastMessage, isFalse);
  });
}
