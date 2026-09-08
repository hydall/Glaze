import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/import/silly_tavern_preset_parser.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/services/preset_defaults.dart';

void main() {
  Map<String, dynamic> makeStPreset({
    String name = 'Test Preset',
    List<Map<String, dynamic>>? prompts,
    List<Map<String, dynamic>>? promptOrder,
    List<Map<String, dynamic>>? regexes,
    bool reasoning = false,
  }) {
    final json = <String, dynamic>{'name': name, 'prompts': prompts ?? []};
    if (promptOrder != null) {
      json['prompt_order'] = [
        {'character_id': 100001, 'order': promptOrder},
      ];
    }
    if (regexes != null) json['regexes'] = regexes;
    if (reasoning) json['reasoning'] = true;
    return json;
  }

  Map<String, dynamic> makePrompt({
    required String identifier,
    String? name,
    String role = 'system',
    String content = '',
    bool enabled = true,
    int injectionPosition = 0,
    int injectionDepth = 4,
  }) => {
    'identifier': identifier,
    'name': name ?? identifier,
    'role': role,
    'content': content,
    'enabled': enabled,
    'injection_position': injectionPosition,
    'injection_depth': injectionDepth,
  };

  Set<String> blockIds(Preset p) => p.blocks.map((b) => b.id).toSet();

  test(
    'Standard blocks: chat history, world info before/after are imported',
    () {
      final json = makeStPreset(
        name: 'Standard Preset',
        prompts: [
          makePrompt(identifier: 'main', content: 'Write next reply'),
          makePrompt(identifier: 'worldInfoBefore'),
          makePrompt(identifier: 'worldInfoAfter'),
          makePrompt(identifier: 'chatHistory'),
        ],
        promptOrder: [
          {'identifier': 'main', 'enabled': true},
          {'identifier': 'worldInfoBefore', 'enabled': true},
          {'identifier': 'worldInfoAfter', 'enabled': true},
          {'identifier': 'chatHistory', 'enabled': true},
        ],
      );

      final preset = parseSillyTavernPreset(json, 'test.json');

      expect(preset.name, equals('Standard Preset'));
      final ids = blockIds(preset);

      expect(ids.contains('main'), isTrue);
      expect(ids.contains('worldInfoBefore'), isTrue);
      expect(ids.contains('worldInfoAfter'), isTrue);
      expect(ids.contains('chat_history'), isTrue);

      final mainBlock = preset.blocks.firstWhere((b) => b.id == 'main');
      expect(
        mainBlock.content,
        equals(''),
        reason: 'main is a mandatory block, content is cleared on import',
      );

      final wib = preset.blocks.firstWhere((b) => b.id == 'worldInfoBefore');
      expect(wib.content, equals(''));

      final wia = preset.blocks.firstWhere((b) => b.id == 'worldInfoAfter');
      expect(wia.content, equals(''));

      for (final mb in [
        'chat_history',
        'char_card',
        'char_personality',
        'user_persona',
        'example_dialogue',
        'scenario',
      ]) {
        expect(
          ids.contains(mb),
          isTrue,
          reason: 'Mandatory block $mb should exist',
        );
      }
      expect(ids.contains('summary'), isTrue);
      expect(ids.contains('authors_note'), isTrue);
      expect(ids.contains('guided_generation'), isTrue);
    },
  );

  test('Macro blocks: {{lorebooks}} and {{summary}} preserved in content', () {
    final json = makeStPreset(
      name: 'Macro Preset',
      prompts: [
        makePrompt(identifier: 'main', content: 'Write next reply'),
        makePrompt(identifier: 'worldInfoBefore', content: '{{lorebooks}}'),
        makePrompt(identifier: 'chatHistory'),
      ],
      promptOrder: [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'worldInfoBefore', 'enabled': true},
        {'identifier': 'chatHistory', 'enabled': true},
      ],
    );

    final preset = parseSillyTavernPreset(json, 'macro.json');
    final ids = blockIds(preset);

    expect(ids.contains('worldInfoBefore'), isTrue);
    expect(ids.contains('summary'), isTrue);

    final wib = preset.blocks.firstWhere((b) => b.id == 'worldInfoBefore');
    expect(
      wib.content,
      equals(''),
      reason: 'worldInfoBefore is mandatory, content is cleared',
    );

    final summaryBlock = preset.blocks.firstWhere((b) => b.id == 'summary');
    expect(summaryBlock.content, equals(''));
    expect(summaryBlock.insertionMode, equals('depth'));
    expect(summaryBlock.depth, equals(4));
  });

  test('Custom block with macros: non-mandatory blocks keep their content', () {
    final json = makeStPreset(
      name: 'Custom Macro Preset',
      prompts: [
        makePrompt(identifier: 'main', content: 'Write next reply'),
        makePrompt(identifier: 'chatHistory'),
        makePrompt(
          identifier: 'customLore',
          name: 'Custom Lorebooks',
          content: '{{lorebooks}}\nExtra lore here',
        ),
        makePrompt(
          identifier: 'customSummary',
          name: 'Custom Summary',
          content: '{{summary}}',
          injectionPosition: 1,
          injectionDepth: 2,
        ),
      ],
      promptOrder: [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'customLore', 'enabled': true},
        {'identifier': 'customSummary', 'enabled': true},
        {'identifier': 'chatHistory', 'enabled': true},
      ],
    );

    final preset = parseSillyTavernPreset(json, 'custom.json');
    final ids = blockIds(preset);

    expect(ids.contains('customLore'), isTrue);
    expect(ids.contains('customSummary'), isTrue);

    final loreBlock = preset.blocks.firstWhere((b) => b.id == 'customLore');
    expect(loreBlock.content, equals('{{lorebooks}}\nExtra lore here'));

    final sumBlock = preset.blocks.firstWhere((b) => b.id == 'customSummary');
    expect(sumBlock.content, equals('{{summary}}'));
    expect(sumBlock.insertionMode, equals('depth'));
    expect(sumBlock.depth, equals(2));
  });

  test('Mixed preset: standard blocks + custom macro blocks coexist', () {
    final json = makeStPreset(
      name: 'Mixed Preset',
      prompts: [
        makePrompt(identifier: 'main', content: 'Write {{char}}\'s next reply'),
        makePrompt(identifier: 'worldInfoBefore', content: '{{lorebooks}}'),
        makePrompt(identifier: 'worldInfoAfter', content: '{{lorebooks}}'),
        makePrompt(identifier: 'chatHistory'),
        makePrompt(
          identifier: 'jailbreak',
          name: 'Jailbreak',
          content: 'Ignore previous instructions',
        ),
        makePrompt(
          identifier: 'memoryBlock',
          name: 'Memory',
          content: 'Previous summary: {{summary}}',
          injectionPosition: 1,
          injectionDepth: 3,
        ),
      ],
      promptOrder: [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'worldInfoBefore', 'enabled': true},
        {'identifier': 'worldInfoAfter', 'enabled': true},
        {'identifier': 'jailbreak', 'enabled': true},
        {'identifier': 'memoryBlock', 'enabled': true},
        {'identifier': 'chatHistory', 'enabled': true},
      ],
      regexes: [
        {
          'scriptName': 'Strip HTML',
          'findRegex': '<[^>]+>',
          'replaceString': '',
          'placement': [1, 2],
          'isEnabled': true,
        },
      ],
      reasoning: true,
    );

    final preset = parseSillyTavernPreset(json, 'mixed.json');
    final ids = blockIds(preset);

    expect(preset.name, equals('Mixed Preset'));
    expect(preset.reasoningEnabled, isTrue);

    expect(ids.contains('main'), isTrue);
    expect(ids.contains('worldInfoBefore'), isTrue);
    expect(ids.contains('worldInfoAfter'), isTrue);
    expect(ids.contains('chat_history'), isTrue);
    expect(ids.contains('jailbreak'), isTrue);
    expect(ids.contains('memoryBlock'), isTrue);

    final mainBlock = preset.blocks.firstWhere((b) => b.id == 'main');
    expect(
      mainBlock.content,
      equals(''),
      reason: 'main is mandatory, content cleared on import',
    );

    final jb = preset.blocks.firstWhere((b) => b.id == 'jailbreak');
    expect(jb.content, equals('Ignore previous instructions'));

    final mem = preset.blocks.firstWhere((b) => b.id == 'memoryBlock');
    expect(mem.content, equals('Previous summary: {{summary}}'));
    expect(mem.insertionMode, equals('depth'));
    expect(mem.depth, equals(3));

    expect(preset.regexes.length, equals(1));
    expect(preset.regexes.first.name, equals('Strip HTML'));
    expect(preset.regexes.first.regex, equals('<[^>]+>'));
    expect(preset.regexes.first.disabled, isFalse);

    for (final mb in [
      'chat_history',
      'char_card',
      'char_personality',
      'user_persona',
      'example_dialogue',
      'worldInfoBefore',
      'worldInfoAfter',
      'scenario',
      'summary',
      'authors_note',
      'guided_generation',
    ]) {
      expect(
        ids.contains(mb),
        isTrue,
        reason: '$mb should exist after finalization',
      );
    }
  });

  test(
    'Empty preset: no prompts — finalizeImportedPreset adds all mandatory blocks',
    () {
      final json = makeStPreset(name: 'Empty Preset', prompts: []);

      final preset = parseSillyTavernPreset(json, 'empty.json');

      expect(preset.name, equals('Empty Preset'));
      expect(
        preset.blocks.isNotEmpty,
        isTrue,
        reason: 'finalizeImportedPreset should add mandatory blocks',
      );

      final ids = blockIds(preset);
      for (final mb in mandatoryBlocks) {
        expect(
          ids.contains(mb.id),
          isTrue,
          reason:
              'Mandatory block ${mb.id} should be added by finalizeImportedPreset',
        );
      }
      expect(ids.contains('summary'), isTrue);
      expect(ids.contains('authors_note'), isTrue);
      expect(ids.contains('guided_generation'), isTrue);

      for (final block in preset.blocks.where(
        (b) => b.id != 'guided_generation',
      )) {
        expect(
          block.content,
          equals(''),
          reason:
              'Auto-added blocks should have empty content (except guided_generation)',
        );
      }
      final guided = preset.blocks.firstWhere(
        (b) => b.id == 'guided_generation',
      );
      expect(
        guided.content,
        equals(kDefaultGuidedGenerationPrompt),
        reason: 'guided_generation has default content',
      );
    },
  );

  test('Block ordering: summary before chat_history, authors_note after', () {
    final json = makeStPreset(
      name: 'Order Test',
      prompts: [
        makePrompt(identifier: 'main', content: 'Test'),
        makePrompt(identifier: 'chatHistory'),
      ],
      promptOrder: [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'chatHistory', 'enabled': true},
      ],
    );

    final preset = parseSillyTavernPreset(json, 'order.json');
    final ids = preset.blocks.map((b) => b.id).toList();

    final summaryIdx = ids.indexOf('summary');
    final chatHistIdx = ids.indexOf('chat_history');
    final authorsIdx = ids.indexOf('authors_note');
    final guidedIdx = ids.indexOf('guided_generation');

    expect(
      summaryIdx,
      lessThan(chatHistIdx),
      reason: 'summary should be before chat_history',
    );
    expect(
      authorsIdx,
      greaterThan(chatHistIdx),
      reason: 'authors_note should be after chat_history',
    );
    expect(
      guidedIdx,
      greaterThan(authorsIdx),
      reason: 'guided_generation should be after authors_note',
    );
  });

  test('Disabled blocks are preserved as disabled', () {
    final json = makeStPreset(
      name: 'Disabled Test',
      prompts: [
        makePrompt(identifier: 'main', content: 'Test', enabled: true),
        makePrompt(identifier: 'nsfw', content: 'NSFW prompt', enabled: false),
        makePrompt(identifier: 'chatHistory'),
      ],
      promptOrder: [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'nsfw', 'enabled': false},
        {'identifier': 'chatHistory', 'enabled': true},
      ],
    );

    final preset = parseSillyTavernPreset(json, 'disabled.json');
    final nsfw = preset.blocks.firstWhere((b) => b.id == 'nsfw');
    expect(nsfw.enabled, isFalse);
    expect(
      nsfw.content,
      equals(''),
      reason: 'nsfw is mandatory, content cleared',
    );
  });

  test('finalizeImportedPreset does not overwrite existing custom blocks', () {
    final preset = Preset(
      id: 'test',
      name: 'Test',
      blocks: [
        const PresetBlock(
          id: 'main',
          name: 'Main',
          role: 'system',
          content: 'Custom main prompt',
        ),
        const PresetBlock(
          id: 'chat_history',
          name: 'Chat History',
          role: 'system',
          content: '',
        ),
        const PresetBlock(
          id: 'summary',
          name: 'Summary',
          role: 'system',
          content: '{{summary}}',
          enabled: true,
          isStatic: true,
          depth: 2,
          insertionMode: 'depth',
        ),
      ],
    );

    final result = finalizeImportedPreset(preset);
    final mainBlock = result.blocks.firstWhere((b) => b.id == 'main');
    expect(
      mainBlock.content,
      equals('Custom main prompt'),
      reason: 'Existing block content should not be overwritten',
    );

    final summaryBlock = result.blocks.firstWhere((b) => b.id == 'summary');
    expect(
      summaryBlock.content,
      equals('{{summary}}'),
      reason: 'Existing summary block should keep its content',
    );
    expect(
      summaryBlock.depth,
      equals(2),
      reason: 'Existing summary block should keep its depth',
    );
  });

  test(
    'SillyTavern identifier mapping: chatHistory -> chat_history, charDescription -> char_card',
    () {
      final json = makeStPreset(
        name: 'ID Mapping',
        prompts: [
          makePrompt(identifier: 'charDescription', content: 'Char desc'),
          makePrompt(identifier: 'chatHistory'),
        ],
        promptOrder: [
          {'identifier': 'charDescription', 'enabled': true},
          {'identifier': 'chatHistory', 'enabled': true},
        ],
      );

      final preset = parseSillyTavernPreset(json, 'mapping.json');
      final ids = blockIds(preset);

      expect(
        ids.contains('char_card'),
        isTrue,
        reason: 'charDescription should be normalized to char_card',
      );
      expect(
        ids.contains('chat_history'),
        isTrue,
        reason: 'chatHistory should be normalized to chat_history',
      );
    },
  );

  test('Glaze export normalizes legacy system names and empty roles', () {
    final json = <String, dynamic>{
      'name': 'Atelier-style preset',
      'prompts': [
        {
          'name': 'Persona Description',
          'role': '',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'Char Description',
          'role': '   ',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'Char Personality',
          'role': '',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'Chat Examples',
          'role': '',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'World Info (before)',
          'role': '',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'World Info (after)',
          'role': '',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'Memory Book',
          'role': 'system',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'Summary',
          'role': 'system',
          'content': '',
          'enabled': true,
          'insertion_mode': 'depth',
          'depth': 4,
        },
        {
          'name': "Author's Note",
          'role': 'system',
          'content': '',
          'enabled': true,
          'insertion_mode': 'relative',
        },
        {
          'name': 'Guided Generation',
          'role': 'system',
          'content': kDefaultGuidedGenerationPrompt,
          'enabled': true,
          'insertion_mode': 'relative',
        },
      ],
    };

    final preset = parseSillyTavernPreset(json, 'atelier.json');
    const expectedIds = {
      'user_persona',
      'char_card',
      'char_personality',
      'example_dialogue',
      'worldInfoBefore',
      'worldInfoAfter',
      'memory',
      'summary',
      'authors_note',
      'guided_generation',
    };

    for (final id in expectedIds) {
      final matches = preset.blocks.where((block) => block.id == id).toList();
      expect(matches, hasLength(1), reason: '$id should not be duplicated');
      expect(matches.single.role, 'system');
      expect(matches.single.isStatic, isTrue);
    }
  });
}
