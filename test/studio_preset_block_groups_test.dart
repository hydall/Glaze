import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_groups.dart';
import 'package:glaze_flutter/core/models/studio_preset_block_migration.dart';

void main() {
  const blocks = [
    StudioPresetBlock(id: 'intro', title: 'Core Directive', order: 1),
    StudioPresetBlock(id: 'pov_header', title: '━🧍 Point-of-View', order: 2),
    StudioPresetBlock(
      id: 'third_person',
      title: 'Third Person Narrator',
      enabled: true,
      order: 3,
    ),
    StudioPresetBlock(
      id: 'second_person',
      title: 'Second Person',
      enabled: false,
      order: 4,
    ),
    StudioPresetBlock(
      id: 'past_tense',
      title: 'Past-Tense Modifier',
      enabled: true,
      order: 5,
    ),
    StudioPresetBlock(
      id: 'present_tense',
      title: 'Present-Tense Modifier',
      enabled: false,
      order: 6,
    ),
    StudioPresetBlock(
      id: 'style_header',
      title: '━✏️ Narrative Styles',
      order: 7,
    ),
    StudioPresetBlock(
      id: 'roleplay',
      title: 'Roleplay',
      enabled: false,
      order: 8,
    ),
    StudioPresetBlock(
      id: 'ao3',
      title: 'AO3-Style Fan Fiction',
      enabled: true,
      order: 9,
    ),
  ];

  test('groups blocks under authored Loom headers in logical order', () {
    final normalized = normalizeStudioGroupBoundaries([
      ...blocks.take(1),
      blocks[1].copyWith(content: '<loompov>\nPOV'),
      ...blocks.skip(2).take(4),
      blocks[6].copyWith(content: '</loompov>\n<loomstyle>\nStyles'),
      ...blocks.skip(7),
      const StudioPresetBlock(
        id: 'style_close',
        title: 'End Narrative Styles',
        content: '</loomstyle>',
        order: 10,
      ),
    ]);
    final items = groupStudioPresetBlocks(normalized);

    expect(items, hasLength(4));
    expect(items[0].standalone?.id, 'intro');
    expect(items[1].header?.id, 'pov_header');
    expect(items[1].openingBoundary?.content, '<loompov>');
    expect(items[1].closingBoundary?.content, '</loompov>');
    expect(items[1].children.map((b) => b.id), [
      'third_person',
      'second_person',
    ]);
    expect(items[1].exclusive, isTrue);
    expect(items[2].header?.title, 'Tense');
    expect(items[2].openingBoundary, isNull);
    expect(items[2].closingBoundary, isNull);
    expect(items[2].children.map((b) => b.id), ['past_tense', 'present_tense']);
    expect(items[2].exclusive, isTrue);
    expect(items[3].header?.id, 'style_header');
    expect(items[3].openingBoundary?.content, '<loomstyle>');
    expect(items[3].closingBoundary?.content, '</loomstyle>');
    expect(items[3].exclusive, isTrue);
  });

  test('explicit closing boundary ends a folder before standalone blocks', () {
    const folder = [
      StudioPresetBlock(id: 'header', title: '━ Folder', order: 0),
      StudioPresetBlock(id: 'child', order: 1),
      StudioPresetBlock(
        id: 'header_group_close',
        groupBoundary: 'close',
        order: 2,
      ),
      StudioPresetBlock(id: 'standalone', order: 3),
    ];

    final groups = groupStudioPresetBlocks(folder);

    expect(groups, hasLength(2));
    expect(groups.first.children.map((block) => block.id), ['child']);
    expect(groups.last.standalone?.id, 'standalone');
  });

  test('locked blocks cannot be disabled through group updates', () {
    const blocks = [StudioPresetBlock(id: 'core', enabled: true, locked: true)];

    final updated = updateStudioPresetBlockRespectingGroups(
      blocks,
      blocks.single.copyWith(enabled: false),
    );

    expect(updated.single.enabled, isTrue);
  });

  test('selecting an exclusive option disables its siblings', () {
    final updated = selectExclusiveStudioBlock(
      blocks,
      groupStudioPresetBlocks(blocks)[1],
      'second_person',
    );

    expect(updated.firstWhere((b) => b.id == 'third_person').enabled, isFalse);
    expect(updated.firstWhere((b) => b.id == 'second_person').enabled, isTrue);
    expect(updated.firstWhere((b) => b.id == 'ao3').enabled, isTrue);
  });

  test('editing an enabled exclusive option disables its siblings', () {
    final updated = updateStudioPresetBlockRespectingGroups(
      blocks,
      blocks
          .firstWhere((block) => block.id == 'second_person')
          .copyWith(enabled: true, content: 'Edited'),
    );

    expect(updated.firstWhere((b) => b.id == 'third_person').enabled, isFalse);
    expect(updated.firstWhere((b) => b.id == 'second_person').enabled, isTrue);
    expect(
      updated.firstWhere((b) => b.id == 'second_person').content,
      'Edited',
    );
  });

  test('treats CoT selections as an exclusive group', () {
    const cotBlocks = [
      StudioPresetBlock(id: 'cot_header', title: '━ CoT Selections', order: 0),
      StudioPresetBlock(id: 'compact', title: 'Compact Planning', order: 1),
      StudioPresetBlock(
        id: 'directional',
        title: 'Directional Planning',
        enabled: false,
        order: 2,
      ),
      StudioPresetBlock(id: 'next_header', title: '━ Final Response', order: 3),
    ];

    final group = groupStudioPresetBlocks(cotBlocks).first;
    expect(group.exclusive, isTrue);
    expect(group.children.map((block) => block.id), ['compact', 'directional']);

    final updated = selectExclusiveStudioBlock(cotBlocks, group, 'directional');
    expect(
      updated.firstWhere((block) => block.id == 'compact').enabled,
      isFalse,
    );
    expect(
      updated.firstWhere((block) => block.id == 'directional').enabled,
      isTrue,
    );
  });

  test('treats text formatting contracts as exclusive options', () {
    const formattingBlocks = [
      StudioPresetBlock(
        id: 'format_header',
        title: '━📋 Text Formatting',
        order: 0,
      ),
      StudioPresetBlock(
        id: 'quote_contract',
        title: 'Dialogue Quote Contract',
        order: 1,
      ),
      StudioPresetBlock(
        id: 'asterisk_contract',
        title: 'Asterisk Roleplay Contract',
        enabled: false,
        order: 2,
      ),
    ];

    final group = groupStudioPresetBlocks(formattingBlocks).single;
    expect(group.exclusive, isTrue);

    final updated = selectExclusiveStudioBlock(
      formattingBlocks,
      group,
      'asterisk_contract',
    );
    expect(
      updated.firstWhere((block) => block.id == 'quote_contract').enabled,
      isFalse,
    );
    expect(
      updated.firstWhere((block) => block.id == 'asterisk_contract').enabled,
      isTrue,
    );
  });

  test('merges Lumia definition and modifiers into one section', () {
    const lumiaBlocks = [
      StudioPresetBlock(
        id: 'lumia_definition',
        title: '━ Lumia Definition',
        order: 0,
      ),
      StudioPresetBlock(
        id: 'lumia_definition_group_open',
        groupBoundary: 'open',
        order: 1,
      ),
      StudioPresetBlock(id: 'lumia_choice', title: 'Lumia', order: 2),
      StudioPresetBlock(
        id: 'lumia_definition_group_close',
        groupBoundary: 'close',
        order: 3,
      ),
      StudioPresetBlock(
        id: 'lumia_modifiers',
        title: '━ Lumia Modifiers',
        order: 4,
      ),
      StudioPresetBlock(id: 'lumia_modifier', title: 'Warm tone', order: 5),
      StudioPresetBlock(
        id: 'lumia_modifiers_group_close',
        groupBoundary: 'close',
        order: 6,
      ),
    ];

    final migrated = migrateStudioPresetBlocksToV2(lumiaBlocks);
    final group = groupStudioPresetBlocks(migrated).single;

    expect(group.header?.title, '━ Lumia');
    expect(group.children.map((block) => block.id), [
      'lumia_choice',
      'lumia_modifier',
    ]);
    expect(group.openingBoundary?.id, 'lumia_definition_group_open');
    expect(group.closingBoundary?.id, 'lumia_definition_group_close');
    expect(
      migrated.map((block) => block.id),
      isNot(contains('lumia_modifiers')),
    );
  });

  test(
    'standalone cleaner toggles stay independent across sequential edits',
    () {
      const cleanerBlocks = [
        StudioPresetBlock(
          id: 'cleaner_jailbreak',
          title: 'Cleaner jailbreak',
          injectionPoint: 'cleaner',
          order: 0,
        ),
        StudioPresetBlock(
          id: 'cleaner_system',
          title: 'Cleaner system prompt',
          injectionPoint: 'cleaner',
          order: 1,
        ),
        StudioPresetBlock(
          id: 'cleaner_aiism',
          title: 'AI-ism cleanup',
          enabled: false,
          injectionPoint: 'cleaner',
          order: 2,
        ),
      ];

      final first = updateStudioPresetBlockRespectingGroups(
        cleanerBlocks,
        cleanerBlocks[0].copyWith(enabled: true),
      );
      final second = updateStudioPresetBlockRespectingGroups(
        first,
        first[1].copyWith(enabled: true),
      );

      expect(second[0].enabled, isTrue);
      expect(second[1].enabled, isTrue);
      expect(second[2].enabled, isFalse);
    },
  );

  test('cross-section blocks do not join an exclusive group', () {
    const interleaved = [
      StudioPresetBlock(id: 'final_before', title: 'Final before', order: 0),
      StudioPresetBlock(
        id: 'cleaner_jailbreak',
        title: 'Cleaner jailbreak',
        injectionPoint: 'cleaner',
        order: 1,
      ),
      StudioPresetBlock(
        id: 'cot_header',
        title: '━ CoT Selections',
        injectionPoint: 'final',
        order: 2,
      ),
      StudioPresetBlock(
        id: 'cot_compact',
        title: 'Compact Planning',
        injectionPoint: 'final',
        order: 3,
      ),
      StudioPresetBlock(
        id: 'cleaner_system',
        title: 'Cleaner system prompt',
        injectionPoint: 'cleaner',
        order: 4,
      ),
      StudioPresetBlock(
        id: 'cleaner_aiism',
        title: 'AI-ism cleanup',
        enabled: true,
        injectionPoint: 'cleaner',
        order: 5,
      ),
      StudioPresetBlock(
        id: 'cleaner_beauty',
        title: 'Beauty post-cleaner',
        enabled: true,
        injectionPoint: 'cleaner',
        order: 6,
      ),
    ];

    final enabled = updateStudioPresetBlockRespectingGroups(
      interleaved,
      interleaved
          .firstWhere((block) => block.id == 'cleaner_system')
          .copyWith(enabled: true),
    );

    expect(
      enabled.firstWhere((block) => block.id == 'cleaner_system').enabled,
      isTrue,
    );
    expect(
      enabled.firstWhere((block) => block.id == 'cleaner_aiism').enabled,
      isTrue,
    );
    expect(
      enabled.firstWhere((block) => block.id == 'cleaner_beauty').enabled,
      isTrue,
    );
  });

  test('keeps narrative modifiers independent inside their folder', () {
    const narrativeBlocks = [
      StudioPresetBlock(
        id: 'style_header',
        title: '━✏️ Narrative Styles',
        order: 0,
      ),
      StudioPresetBlock(id: 'ao3', title: 'AO3-Style Fan Fiction', order: 1),
      StudioPresetBlock(
        id: 'endless',
        title: 'Endless Storytelling',
        enabled: false,
        order: 2,
      ),
      StudioPresetBlock(
        id: 'bratty',
        title: 'Bratty Ass Narrative',
        enabled: false,
        order: 3,
      ),
      StudioPresetBlock(
        id: 'anime',
        title: 'Anime-Style Story',
        enabled: false,
        order: 4,
      ),
      StudioPresetBlock(
        id: 'doujinshi',
        title: 'Doujinshi Narrative',
        enabled: false,
        order: 5,
      ),
      StudioPresetBlock(
        id: 'deflections',
        title: 'Emotional Deflections',
        enabled: false,
        order: 6,
      ),
    ];

    final items = groupStudioPresetBlocks(narrativeBlocks);

    expect(items, hasLength(1));
    final group = items.single;
    expect(group.exclusive, isTrue);
    expect(group.children.map((block) => block.id), [
      'ao3',
      'endless',
      'bratty',
      'anime',
      'doujinshi',
      'deflections',
    ]);
    expect(
      group.children
          .where((block) => isIndependentStudioGroupChild(group, block))
          .map((block) => block.id),
      ['bratty', 'doujinshi', 'deflections'],
    );

    final withBratty = updateStudioPresetBlockRespectingGroups(
      narrativeBlocks,
      narrativeBlocks
          .firstWhere((block) => block.id == 'bratty')
          .copyWith(enabled: true),
    );
    expect(withBratty.firstWhere((block) => block.id == 'ao3').enabled, isTrue);
    expect(
      withBratty.firstWhere((block) => block.id == 'bratty').enabled,
      isTrue,
    );

    final withAnime = selectExclusiveStudioBlock(
      withBratty,
      groupStudioPresetBlocks(withBratty).single,
      'anime',
    );
    expect(withAnime.firstWhere((block) => block.id == 'ao3').enabled, isFalse);
    expect(
      withAnime.firstWhere((block) => block.id == 'anime').enabled,
      isTrue,
    );
    expect(
      withAnime.firstWhere((block) => block.id == 'bratty').enabled,
      isTrue,
    );
  });

  test('folder toggle preserves child selections and suppresses injection', () {
    const folderBlocks = [
      StudioPresetBlock(
        id: 'folder_group_open',
        content: '<folder>',
        groupBoundary: 'open',
        order: 0,
      ),
      StudioPresetBlock(
        id: 'folder',
        title: '━ Folder',
        content: 'Header',
        order: 1,
      ),
      StudioPresetBlock(id: 'first', content: 'First', order: 2),
      StudioPresetBlock(
        id: 'second',
        content: 'Second',
        enabled: false,
        order: 3,
      ),
      StudioPresetBlock(
        id: 'folder_group_close',
        content: '</folder>',
        groupBoundary: 'close',
        order: 4,
      ),
      StudioPresetBlock(id: 'outside', content: 'Outside', order: 5),
    ];
    final group = groupStudioPresetBlocks(folderBlocks).first;

    final disabled = toggleStudioPresetBlockGroup(folderBlocks, group, false);
    expect(disabled.firstWhere((block) => block.id == 'first').enabled, isTrue);
    expect(
      disabled.firstWhere((block) => block.id == 'second').enabled,
      isFalse,
    );
    expect(
      resolveEnabledStudioPresetBlocks(disabled).map((block) => block.id),
      ['outside'],
    );

    final restored = toggleStudioPresetBlockGroup(disabled, group, true);
    final resolved = resolveEnabledStudioPresetBlocks(restored);
    expect(resolved.map((block) => block.id), ['folder', 'first', 'outside']);
    expect(resolved.first.content, '<folder>\nHeader');
    expect(resolved[1].content, 'First\n</folder>');
  });

  test('repairs a mismatched legacy close from the owned opening tag', () {
    const legacy = [
      StudioPresetBlock(
        id: 'plot_header',
        title: '━🚧 Plot Progression',
        content: '<loomplot>\nPlot instructions',
        order: 1,
      ),
      StudioPresetBlock(id: 'plot_variant', title: 'Progress', order: 2),
      StudioPresetBlock(
        id: 'length_header',
        title: '━📐 Response Length Controls',
        content: '</loomplotprog>\n<loomlength>\nLength instructions',
        order: 3,
      ),
      StudioPresetBlock(id: 'length_close', content: '</loomlength>', order: 4),
    ];

    final normalized = normalizeStudioGroupBoundaries(legacy);

    expect(
      normalized.firstWhere((b) => b.id == 'plot_header_group_close').content,
      '</loomplot>',
    );
  });

  test('replaces a mismatched final standalone close', () {
    const legacy = [
      StudioPresetBlock(
        id: 'lore_header',
        title: '━ Lore',
        content: '<loomlore>\nLore instructions',
        order: 0,
      ),
      StudioPresetBlock(id: 'lore_option', content: 'Option', order: 1),
      StudioPresetBlock(
        id: 'legacy_close',
        role: 'system',
        content: '</loomwrong>',
        order: 2,
      ),
    ];

    final normalized = normalizeStudioGroupBoundaries(legacy);

    expect(normalized.any((block) => block.content == '</loomwrong>'), isFalse);
    expect(
      normalized.where((block) => block.content == '</loomlore>'),
      hasLength(1),
    );
    expect(normalized.last.id, 'lore_header_group_close');
  });

  test('normalizes legacy cross-group tags into owned boundary blocks', () {
    const legacy = [
      StudioPresetBlock(
        id: 'pov_header',
        title: '━🧍 Point-of-View',
        content: '</lumiapers>\n\n<loompov>\nPOV instructions',
        order: 1,
      ),
      StudioPresetBlock(id: 'third_person', title: 'Third Person', order: 2),
      StudioPresetBlock(
        id: 'human_header',
        title: '━🧑 User Instructions',
        content: '</loompov>\n\n<loomhuman>\nHuman instructions',
        order: 3,
      ),
      StudioPresetBlock(
        id: 'human_close',
        title: 'End User Instructions',
        content: '</loomhuman>',
        order: 4,
      ),
    ];

    final normalized = normalizeStudioGroupBoundaries(legacy);

    expect(normalized.map((block) => block.id), [
      'pov_header_prefix_close',
      'pov_header_group_open',
      'pov_header',
      'third_person',
      'pov_header_group_close',
      'human_header_group_open',
      'human_header',
      'human_header_group_close',
    ]);
    expect(normalized[0].type, StudioBlockType.instruction);
    expect(normalized[0].content, '</lumiapers>');
    expect(normalized[1].type, StudioBlockType.instruction);
    expect(normalized[1].content, '<loompov>');
    expect(normalized[2].content, 'POV instructions');
    expect(normalized[4].type, StudioBlockType.instruction);
    expect(normalized[4].content, '</loompov>');
    expect(normalized[5].content, '<loomhuman>');
    expect(normalized[6].content, 'Human instructions');
    expect(normalized.last.type, StudioBlockType.instruction);
  });
}
