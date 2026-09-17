import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/info_blocks_provider.dart';
import 'package:glaze_flutter/features/extensions/services/ext_blocks_panel_builder.dart';

const _sessionId = 's1';
const _messageId = 'm1';

/// The panel key a chat message produces: `agentSwipeId` comes from the
/// message, whose freezed default is 0 even when its blocks were stored with
/// the legacy -1 binding.
const ExtBlocksPanelKey _messageKey = (
  sessionId: _sessionId,
  messageId: _messageId,
  swipeId: 0,
  agentSwipeId: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> containerWith(List<BlockConfig> blocks) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionPresetsProvider.notifier)
        .add(ExtensionPreset(id: 'p1', name: 'Preset', blocks: blocks));
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p1'));
    // Settle the notifier's own initial load before any row is inserted, so a
    // later refresh() can't be overwritten by it.
    await container.read(infoBlocksProvider(_sessionId).notifier).refresh();
    return container;
  }

  Future<void> storeRow(
    ProviderContainer container, {
    required String blockId,
    required int agentSwipeId,
    String blockType = 'infoblock',
    BlockRunStatus status = BlockRunStatus.done,
  }) async {
    await container.read(infoBlocksRepoProvider).insert(
      InfoBlock(
        id: 'row-$blockId',
        sessionId: _sessionId,
        messageId: _messageId,
        agentSwipeId: agentSwipeId,
        blockId: blockId,
        blockName: blockId,
        blockType: blockType,
        content: 'stored',
        createdAt: 1,
        status: status,
      ),
    );
    await container.read(infoBlocksProvider(_sessionId).notifier).refresh();
  }

  List<String> statusesOf(ProviderContainer container) => [
    for (final block in container.read(extBlocksPanelBlocksProvider(_messageKey)))
      '${block['blockId']}:${block['status']}',
  ];

  test('running a pending block keeps its legacy-bound siblings visible', () async {
    final container = await containerWith(const [
      BlockConfig(id: 'b1', name: 'First', order: 0),
      BlockConfig(id: 'b2', name: 'Second', order: 1),
    ]);
    // The first block ran through the no-cleaner path, so it is stored at -1
    // while the message itself carries agentSwipeId 0.
    await storeRow(container, blockId: 'b1', agentSwipeId: -1);

    expect(statusesOf(container), ['b1:done', 'b2:pending']);

    final notifier = container.read(infoBlocksProvider(_sessionId).notifier);
    final binding = notifier.resolveAgentSwipeId(
      _messageId,
      agentSwipeId: _messageKey.agentSwipeId,
    );
    expect(binding, -1);

    // The second block's own first run writes its row under the resolved
    // binding, so both blocks stay in the panel.
    await storeRow(container, blockId: 'b2', agentSwipeId: binding);
    expect(statusesOf(container), ['b1:done', 'b2:done']);
  });

  test('resolveAgentSwipeId keeps the exact binding when rows already use it', () async {
    final container = await containerWith(const [
      BlockConfig(id: 'b1', name: 'First'),
    ]);
    final notifier = container.read(infoBlocksProvider(_sessionId).notifier);

    expect(notifier.resolveAgentSwipeId(_messageId, agentSwipeId: 0), 0);

    await storeRow(container, blockId: 'b1', agentSwipeId: 0);
    expect(notifier.resolveAgentSwipeId(_messageId, agentSwipeId: 0), 0);
  });

  test('only blocks that can run here get a pending placeholder', () async {
    final container = await containerWith(const [
      BlockConfig(id: 'assistant', name: 'Assistant', order: 0),
      BlockConfig(
        id: 'user',
        name: 'User',
        trigger: BlockTrigger.afterUser,
        order: 1,
      ),
      BlockConfig(
        id: 'periodic',
        name: 'Periodic',
        type: BlockType.jsRunner,
        trigger: BlockTrigger.periodic,
        order: 2,
      ),
      BlockConfig(
        id: 'rewrite',
        name: 'Rewrite',
        type: BlockType.rewrite,
        order: 3,
      ),
    ]);

    expect(statusesOf(container), ['assistant:pending']);

    // A row that does exist still renders, whatever the block's trigger is.
    await storeRow(container, blockId: 'user', agentSwipeId: -1);
    expect(statusesOf(container), ['assistant:pending', 'user:done']);
  });

  test('run-all stays hidden when only a manual-only block is unfinished', () async {
    final container = await containerWith(const [
      BlockConfig(id: 'auto', name: 'Auto', order: 0),
      BlockConfig(id: 'manual', name: 'Manual', manualOnly: true, order: 1),
    ]);
    await storeRow(container, blockId: 'auto', agentSwipeId: -1);

    expect(statusesOf(container), ['auto:done', 'manual:pending']);
    expect(container.read(extBlocksPanelCanRunAllProvider(_messageKey)), isFalse);
  });

  test('run-all shows up while an automatic block is unfinished', () async {
    final container = await containerWith(const [
      BlockConfig(id: 'auto', name: 'Auto', order: 0),
      BlockConfig(id: 'second', name: 'Second', order: 1),
    ]);
    await storeRow(container, blockId: 'auto', agentSwipeId: -1);

    expect(container.read(extBlocksPanelCanRunAllProvider(_messageKey)), isTrue);
  });
}
