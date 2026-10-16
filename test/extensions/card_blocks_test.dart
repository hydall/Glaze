import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/services/card_blocks.dart';
import 'package:glaze_flutter/features/extensions/widgets/ext_blocks_settings_sheet.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';

void main() {
  group('reading a card', () {
    test('takes the original\'s blocks, with a stable id for id-less ones', () {
      final raw = [
        {
          'id': 'u1',
          'name': 'stats',
          'block_type': 'generated',
          'prompt': 'Track it.',
          'char_message': true,
        },
        {'name': 'mood', 'block_type': 'script', 'script': 'return 1;'},
        'junk',
      ];
      final first = decodeCardBlocks(raw);
      expect(first.map((b) => b.name), ['stats', 'mood']);
      expect(first[0].id, 'u1');
      expect(first[0].triggerOnChar, isTrue);
      expect(first[1].type, BlockType.script);
      expect(first[1].id, decodeCardBlocks(raw)[1].id);
      expect(first.map((b) => b.order), [0, 1]);
      expect(decodeCardBlocks(null), isEmpty);
      expect(cardBlocksOf(const Character(id: 'c', name: 'C')), isEmpty);
    });

    test('keeps Glaze-only settings until the block is edited elsewhere', () {
      const block = BlockConfig(
        id: 'b',
        name: 'stats',
        prompt: 'Track it.',
        render: BlockRender.card,
        panelMinHeight: 321,
      );
      final stored = encodeCardBlocks([block]);
      expect(stored.single['name'], 'stats');
      expect(stored.single['prompt'], 'Track it.');

      final read = decodeCardBlocks(stored).single;
      expect(read.render, BlockRender.card);
      expect(read.panelMinHeight, 321);

      // Edited in the original: its fields win, our copy is dropped.
      final edited = [
        {...stored.single, 'prompt': 'Changed.'},
      ];
      final reread = decodeCardBlocks(edited).single;
      expect(reread.prompt, 'Changed.');
      expect(reread.render, BlockRender.message);
    });
  });

  test('card blocks come first and replace preset blocks by name', () {
    const preset = ExtensionPreset(
      id: 'p',
      name: 'P',
      blocks: [
        BlockConfig(id: 'p1', name: 'stats', order: 0),
        BlockConfig(id: 'p2', name: 'tracker', order: 1),
      ],
    );
    final merged = withCardBlocks(preset, const [
      BlockConfig(id: 'c1', name: 'mood'),
      BlockConfig(id: 'c2', name: 'stats'),
    ]);
    expect(merged.blocks.map((b) => b.id), ['c1', 'c2', 'p2']);
    expect(merged.blocks.map((b) => b.order), [0, 1, 2]);
    expect(withCardBlocks(preset, const []), same(preset));
  });

  test('card blocks are written into the card and read back', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final repo = container.read(characterRepoProvider);
    await repo.put(
      const Character(id: 'c', name: 'C', extensions: {'other': 1}),
    );

    await saveCardBlocks(container.read, 'c', const [
      BlockConfig(id: 'b', name: 'stats', order: 5),
    ]);
    var character = await repo.getById('c');
    expect(character!.extensions['other'], 1);
    expect(cardBlocksOf(character).single.name, 'stats');
    expect(cardBlocksOf(character).single.order, 0);

    await saveCardBlocks(container.read, 'c', const []);
    character = await repo.getById('c');
    expect(character!.extensions.containsKey(cardBlocksKey), isFalse);
  });

  test('a session names its character without loading messages', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = ChatRepo(db);
    await repo.put(
      const ChatSession(id: 's1', characterId: 'c1', sessionIndex: 0),
    );
    expect(await repo.characterIdOf('s1'), 'c1');
    expect(await repo.characterIdOf('missing'), isNull);
  });

  testWidgets('the panel lists the card blocks and switches them in the card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionPresetsProvider.notifier)
        .add(
          const ExtensionPreset(
            id: 'p1',
            name: 'Preset',
            blocks: [BlockConfig(id: 'b1', name: 'Ledger')],
          ),
        );
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(activePresetId: 'p1'));
    await container
        .read(characterRepoProvider)
        .put(
          Character(
            id: 'c',
            name: 'C',
            extensions: {
              cardBlocksKey: encodeCardBlocks(const [
                BlockConfig(id: 'k', name: 'Mood'),
              ]),
            },
          ),
        );
    await container.read(charactersProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ExtBlocksSettingsSheet(charId: 'c')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ledger'), findsOneWidget);
    expect(find.text('Mood'), findsOneWidget);
    expect(
      find.textContaining('extblocks_card_blocks_section'),
      findsOneWidget,
    );

    final toggle = find.descendant(
      of: find.ancestor(
        of: find.text('Mood'),
        matching: find.byType(MenuScriptItem),
      ),
      matching: find.byType(Switch),
    );
    await tester.runAsync(() async {
      await tester.tap(toggle);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final character = await tester.runAsync(
      () => container.read(characterRepoProvider).getById('c'),
    );
    expect(cardBlocksOf(character).single.enabled, isFalse);
    // The preset itself is untouched.
    expect(
      container.read(extensionPresetsProvider).single.blocks,
      hasLength(1),
    );
  });
}
