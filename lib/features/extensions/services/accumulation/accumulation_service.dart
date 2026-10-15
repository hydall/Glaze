import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../../shared/widgets/glaze_toast.dart';
import '../../models/block_config.dart';
import '../../models/block_run_status.dart';
import '../../models/extension_preset.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import '../block_content_extractor.dart';
import '../blocks/block_tag_utils.dart';
import '../blocks/block_trigger_rules.dart';
import 'mongo_update.dart';
import 'yaml_codec.dart';

/// The instruction the original's editor copies for the model, telling it
/// how to write the updater for [blockName] in [updaterName].
String accumulationUpdaterPrompt(String blockName, String updaterName) {
  final block = blockName.trim().isEmpty ? 'block_name' : blockName.trim();
  final updater = updaterName.trim().isEmpty
      ? 'updater_name'
      : updaterName.trim();
  return 'To update the <$block> block, use the <$updater> block with '
      'MongoDB-style operators (\$set, \$inc, \$push, \$pull, \$unset, '
      '\$min, \$max, \$mul, etc.) in YAML format. Dot notation (e.g., '
      'path.to.0.field) and arrayFilters are supported.\n'
      'Example:\n'
      '<$updater>\n'
      '\$inc:\n'
      '  gold: 10\n'
      '\$push:\n'
      '  inventory: Sword\n'
      '\$set:\n'
      '  status.is_happy: true\n'
      '  "knownLocations.\$[elem].visited": true\n'
      'arrayFilters:\n'
      '  - "elem.name": "Village"\n'
      '</$updater>';
}

final extBlocksAccumulatorProvider = Provider<ExtBlocksAccumulator>(
  (ref) => ExtBlocksAccumulator(ref),
);

/// What went wrong in one accumulation step, for the toast.
enum AccumulationError { parseState, parseUpdate, applyUpdate }

/// One accumulation step: the new state, or `null` when the update could not
/// be applied, and the errors met on the way.
typedef AccumulationStep = ({
  String? state,
  List<(AccumulationError, String)> errors,
});

/// Applies the YAML update [updaterText] to the YAML document
/// [previousState], as the original's `AccumulationPlugin` does.
///
/// A state or an update that does not parse counts as an empty map, with an
/// error reported — the original's `parseYaml`. An update that cannot be
/// applied leaves no new state.
AccumulationStep accumulateYaml({
  required String previousState,
  required String updaterText,
}) {
  final errors = <(AccumulationError, String)>[];
  Object? parse(String text, AccumulationError kind) {
    try {
      return parseYaml(text);
    } on YamlException catch (e) {
      errors.add((kind, e.message));
      return const <String, Object?>{};
    }
  }

  final parsed = previousState.trim().isEmpty
      ? null
      : parse(previousState, AccumulationError.parseState);
  final doc = parsed is Map
      ? <String, Object?>{for (final e in parsed.entries) '${e.key}': e.value}
      : <String, Object?>{};
  final update = parse(updaterText, AccumulationError.parseUpdate);
  try {
    applyMongoUpdate(doc, update);
  } on MongoUpdateError catch (e) {
    errors.add((AccumulationError.applyUpdate, e.message));
    return (state: null, errors: errors);
  }
  return (state: dumpYaml(doc).trim(), errors: errors);
}

/// Runs accumulation blocks: a block keeps a YAML state document, and an
/// "updater" block — `<updater_name>` in a message or in a generated block's
/// output — changes it with MongoDB-style operators.
///
/// The state lives as the block's row under the message that changed it. A
/// run starts from the latest state at or before that message, so state
/// carries forward through the chat and a swipe sees its own history.
class ExtBlocksAccumulator {
  ExtBlocksAccumulator(this._ref);

  final Ref _ref;

  InfoBlocksRepository get _repo => _ref.read(infoBlocksRepoProvider);

  /// The enabled accumulation blocks of [preset] that answer to [side].
  /// Keyword and period do not apply: an updater in the text is the trigger.
  static List<BlockConfig> blocksFor(
    ExtensionPreset preset,
    BlockTrigger side,
  ) => [
    for (final b in preset.blocks)
      if (b.enabled &&
          b.type == BlockType.accumulation &&
          b.updaterName.trim().isNotEmpty &&
          b.runsOn(side))
        b,
  ];

  /// Rebuilds the accumulation state of [messageId] from scratch: drops what
  /// it had, applies the updaters in the message text, then those in the
  /// generated blocks stored under it — the original's two passes, before
  /// and after generation.
  ///
  /// Starting over each time is what keeps a re-run from applying the same
  /// `$inc` twice.
  Future<void> rebuildForMessage({
    required ExtensionPreset preset,
    required BlockTrigger side,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<ChatMessage> messages,
  }) async {
    final blocks = blocksFor(preset, side);
    if (blocks.isEmpty) return;
    await resetForMessage(
      blocks: blocks,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final message = messages.where((m) => m.id == messageId).firstOrNull;
    if (message == null) return;
    final target = (
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      messages: messages,
    );
    await accumulate(blocks: blocks, target: target, text: message.content);
    await accumulate(
      blocks: blocks,
      target: target,
      text: await generatedOutput(
        preset: preset,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
      ),
    );
  }

  /// Deletes the state rows [blocks] left under [messageId].
  Future<void> resetForMessage({
    required List<BlockConfig> blocks,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) async {
    final ids = {for (final b in blocks) b.id};
    final notifier = _ref.read(infoBlocksProvider(sessionId).notifier);
    final rows = await _repo.getByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    for (final row in rows) {
      if (ids.contains(row.blockId)) await notifier.delete(row.id);
    }
  }

  /// The finished generated blocks under [messageId], each in its tag, as the
  /// original hands its generated blocks to the second pass.
  Future<String> generatedOutput({
    required ExtensionPreset preset,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
  }) async {
    final configs = {for (final b in preset.blocks) b.id: b};
    final rows = await _repo.getByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final parts = <String>[];
    for (final row in rows) {
      final config = configs[row.blockId];
      if (config == null || config.type != BlockType.generated) continue;
      if (row.status != BlockRunStatus.done) continue;
      final content = row.content.trim();
      if (content.isEmpty) continue;
      final tag = blockTagName(config, config.template);
      parts.add(
        content.contains('<$tag') ? content : '<$tag>\n$content\n</$tag>',
      );
    }
    return parts.join('\n');
  }

  /// Applies every updater of [blocks] found in [text] to its block's latest
  /// state and stores the result under the target message. Blocks are taken
  /// one after another, so a block named twice sees its own first update.
  Future<void> accumulate({
    required List<BlockConfig> blocks,
    required AccumulationTarget target,
    required String text,
  }) async {
    if (text.isEmpty) return;
    for (final block in blocks) {
      final updater = block.updaterName.trim();
      if (!text.contains('<$updater>')) continue;
      final updaterText = multiBlockContentFromMessage(text, updater);
      if (updaterText.isEmpty) continue;

      final previous = await _latestState(block, target);
      final step = accumulateYaml(
        previousState: previous,
        updaterText: updaterText,
      );
      for (final (kind, detail) in step.errors) {
        debugPrint('[ExtBlocks] accumulation "${block.name}" $kind: $detail');
        _toast(switch (kind) {
          AccumulationError.parseState || AccumulationError.parseUpdate =>
            'extblocks_accumulation_parse_failed'.tr(args: [block.name]),
          AccumulationError.applyUpdate =>
            'extblocks_accumulation_apply_failed'.tr(
              args: [block.name, detail],
            ),
        });
      }
      final state = step.state;
      if (state != null) await _store(block, target, state);
    }
  }

  /// The block's state at the target message: its own row when it has one,
  /// otherwise the newest one before it on the swipes the chat shows.
  Future<String> _latestState(
    BlockConfig block,
    AccumulationTarget target,
  ) async {
    final index = target.messages.indexWhere((m) => m.id == target.messageId);
    if (index < 0) return '';
    for (var i = index; i >= 0; i--) {
      final message = target.messages[i];
      final current = i == index;
      final rows = await _repo.getByMessageId(
        target.sessionId,
        message.id,
        swipeId: current ? target.swipeId : message.swipeId,
        agentSwipeId: current ? target.agentSwipeId : null,
      );
      for (final row in rows) {
        if (row.blockId != block.id) continue;
        if (row.status != BlockRunStatus.done) continue;
        if (row.content.trim().isEmpty) continue;
        return row.content;
      }
    }
    return '';
  }

  Future<void> _store(
    BlockConfig block,
    AccumulationTarget target,
    String state,
  ) async {
    final notifier = _ref.read(infoBlocksProvider(target.sessionId).notifier);
    final rows = await _repo.getByMessageId(
      target.sessionId,
      target.messageId,
      swipeId: target.swipeId,
      agentSwipeId: target.agentSwipeId,
    );
    final existing = rows.where((r) => r.blockId == block.id).firstOrNull;
    if (existing != null) {
      await _repo.updateContent(existing.id, state);
      await _repo.updateStatus(existing.id, BlockRunStatus.done);
      notifier.addOrReplace(
        existing.copyWith(content: state, status: BlockRunStatus.done),
      );
      return;
    }
    final row = InfoBlock(
      id: generateId(),
      sessionId: target.sessionId,
      messageId: target.messageId,
      swipeId: target.swipeId,
      agentSwipeId: target.agentSwipeId,
      blockId: block.id,
      blockName: block.name,
      blockType: block.type.name,
      content: state,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      order: block.order,
    );
    await _repo.insert(row);
    notifier.addOrReplace(row);
  }

  void _toast(String text) {
    try {
      GlazeToast.showWithoutContext(text, isError: true);
    } catch (e) {
      debugPrint('[ExtBlocks] $text');
    }
  }
}

/// The message an accumulation run stores its state under.
typedef AccumulationTarget = ({
  String sessionId,
  String messageId,
  int swipeId,
  int agentSwipeId,
  List<ChatMessage> messages,
});
