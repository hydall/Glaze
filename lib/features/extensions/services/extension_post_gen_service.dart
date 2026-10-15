import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/info_blocks_repository.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../core/state/db_provider.dart';
import '../models/block_config.dart';
import '../models/block_modes.dart';
import '../models/extension_preset.dart';
import '../models/info_block.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import '../providers/info_blocks_provider.dart';
import 'accumulation/accumulation_service.dart';
import 'info_block_service.dart';
import 'rewrite/rewrite_service.dart';
import 'blocks/block_processor.dart';
import 'blocks/block_context.dart';
import 'blocks/block_grouping.dart';
import 'blocks/block_handler.dart';
import 'blocks/block_image_renderer.dart';
import 'blocks/block_panel_updater.dart';
import 'blocks/generated_block_handler.dart';
import 'blocks/js_block_executor.dart';
import 'blocks/script_block_handler.dart';
import 'blocks/block_status_tracker.dart';
import 'blocks/block_trigger_rules.dart';
import 'blocks/periodic_js_block_runner.dart';
import 'blocks/single_block_runner.dart';
import 'blocks/unsupported_block_handler.dart';

final extensionPostGenServiceProvider = Provider<ExtensionPostGenService>(
  (ref) => ExtensionPostGenService(ref),
);

/// Orchestrates extension block generation after chat response.
/// Blocks are run in `order` sequence; blocks with [BlockConfig.dependsOnPrevious]
/// wait for the previous block to finish (done or error) before starting.
/// Independently-configured blocks start in parallel with the previous one.
class ExtensionPostGenService {
  ExtensionPostGenService(this._ref) : _panelUpdater = BlockPanelUpdater(_ref);

  final Ref _ref;
  final BlockPanelUpdater _panelUpdater;

  /// Active cancel tokens for block runs, each with the number of holders
  /// still using it. Multiple chains can overlap (for example, an
  /// afterAssistant image block and afterUser blocks from the next message),
  /// so a single mutable token would orphan older runs; and a background block
  /// outlives its chain, so it holds the token until it is done.
  final Map<CancelToken, int> _blocksCancelTokens = <CancelToken, int>{};

  final BlockProcessor _blockProcessor = const BlockProcessor();

  InfoBlocksRepository get _repo => _ref.read(infoBlocksRepoProvider);

  BlockStatusTracker get _statusTracker => BlockStatusTracker(
    ref: _ref,
    repo: _repo,
    refreshPanelForMessage: _refreshPanelForMessage,
  );

  void _refreshPanelForMessage(
    String charId,
    String sessionId,
    String messageId,
    int swipeId,
    int agentSwipeId,
  ) {
    _panelUpdater.refreshForMessage(
      charId,
      sessionId,
      messageId,
      swipeId,
      agentSwipeId,
    );
  }

  Future<InfoBlock> _markContextBlockError({
    required BlockContext context,
    required String errorMessage,
  }) {
    return _statusTracker.markError(
      context: context,
      errorMessage: errorMessage,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Runs all enabled preset blocks for [messageId]. Used after chat
  /// generation and from the manual "Запустить блоки" control.
  ///
  /// [respectTriggerConditions] applies each block's keyword or period to the
  /// message, as an automatic run does. A manual run leaves it off: the user
  /// asked for the blocks, so every one of them runs.
  Future<bool> runBlocksForMessage({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<ChatMessage> messages,
    required Character character,
    required Persona? persona,
    bool clearExisting = true,
    void Function()? onStarted,
    MainModelContextSnapshot? mainModelContextSnapshot,
    bool respectTriggerConditions = false,
  }) async {
    final preset = _resolveActivePreset();
    if (preset == null) return false;
    final where = respectTriggerConditions
        ? _conditionsFor(messages, messageId, isUser: false)
        : null;
    final blocks = _blockProcessor
        .selectBlocks(preset, BlockTrigger.afterAssistant, where: where)
        .where((b) => b.type != BlockType.accumulation)
        .toList();
    if (blocks.isEmpty &&
        ExtBlocksAccumulator.blocksFor(
          preset,
          BlockTrigger.afterAssistant,
        ).isEmpty) {
      return false;
    }

    onStarted?.call();

    if (clearExisting) {
      await _clearRowsForBlocks(
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        blockIds: {for (final block in blocks) block.id},
      );
    }

    _refreshPanelForMessage(
      charId,
      sessionId,
      messageId,
      swipeId,
      agentSwipeId,
    );

    final cancelToken = _startBlockRun();
    try {
      await _runChain(
        charId: charId,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        messages: messages,
        preset: preset,
        character: character,
        persona: persona,
        cancelToken: cancelToken,
        trigger: BlockTrigger.afterAssistant,
        mainModelContextSnapshot: mainModelContextSnapshot,
        where: where,
      );
    } finally {
      _finishBlockRun(cancelToken);
      _refreshPanelForMessage(
        charId,
        sessionId,
        messageId,
        swipeId,
        agentSwipeId,
      );
    }
    return true;
  }

  /// Drops the stored rows of the blocks this run is about to re-create, and
  /// only those. A manual-only block's result, or one left by a block that no
  /// longer belongs to the automatic chain, is not this run's to delete —
  /// wiping it would blank a panel entry nothing is going to fill again.
  Future<void> _clearRowsForBlocks({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required Set<String> blockIds,
  }) async {
    final notifier = _ref.read(infoBlocksProvider(sessionId).notifier);
    final rows = await _repo.getByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    for (final row in rows) {
      if (!blockIds.contains(row.blockId)) continue;
      await notifier.delete(row.id);
    }
  }

  /// The active preset's enabled rewrite blocks, for the manual rewrite sheet.
  List<BlockConfig> rewriteBlocks() {
    final preset = _resolveActivePreset();
    if (preset == null) return const [];
    return [
      for (final block in preset.blocks)
        if (block.enabled && block.type == BlockType.rewrite) block,
    ];
  }

  /// Runs the rewrite block [blockId] on [messageId] by hand, as the
  /// original's selection popup does. [textToRewrite] narrows it to a
  /// fragment that must occur once in the message; [additionalPrompt] fills
  /// `{{additionalPrompt}}`. Stop reaches it like any other block run.
  Future<void> runRewriteBlock({
    required String blockId,
    required String charId,
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required Character character,
    required Persona? persona,
    String? textToRewrite,
    String additionalPrompt = '',
  }) async {
    final preset = _resolveActivePreset();
    final block = preset?.blocks.where((b) => b.id == blockId).firstOrNull;
    if (preset == null || block == null || block.type != BlockType.rewrite) {
      return;
    }
    final cancelToken = _startBlockRun();
    try {
      await _ref
          .read(extBlocksRewriteServiceProvider)
          .rewriteMessage(
            blocks: [block],
            charId: charId,
            sessionId: sessionId,
            messageId: messageId,
            messages: messages,
            character: character,
            persona: persona,
            preset: preset,
            textToRewrite: textToRewrite,
            additionalMacros: {'additionalPrompt': additionalPrompt},
            cancelToken: cancelToken,
          );
    } finally {
      _finishBlockRun(cancelToken);
    }
  }

  ExtensionPreset? _resolveActivePreset() {
    final settings = _ref.read(extensionsSettingsProvider);
    final presetId = settings.activePresetId;
    if (presetId == null || presetId.isEmpty) {
      return null;
    }
    final preset = _ref
        .read(extensionPresetsProvider)
        .where((pr) => pr.id == presetId)
        .firstOrNull;
    if (preset == null) {
      return null;
    }
    return preset;
  }

  /// Called by ExtBlocksStage after assistant message is finalised.
  /// When the POST-cleaner is enabled, [agentSwipeId] identifies the blue
  /// cleaned sub-swipe the blocks should bind to (and read for content).
  /// When the cleaner is disabled or skipped, [agentSwipeId] stays -1
  /// (legacy: blocks bind to the top-level swipe only).
  Future<bool> processAfterGeneration({
    required String charId,
    required ChatSession session,
    required Character character,
    required Persona? persona,
    int agentSwipeId = -1,
    void Function()? onStarted,
    MainModelContextSnapshot? mainModelContextSnapshot,
  }) async {
    if (session.id.isEmpty || session.messages.isEmpty) return false;

    final lastMessage = session.messages.last;
    if (lastMessage.role == 'user') {
      return false;
    }

    return runBlocksForMessage(
      charId: charId,
      sessionId: session.id,
      messageId: lastMessage.id,
      swipeId: lastMessage.swipeId,
      agentSwipeId: agentSwipeId,
      messages: session.messages,
      character: character,
      persona: persona,
      onStarted: onStarted,
      mainModelContextSnapshot: mainModelContextSnapshot,
      respectTriggerConditions: true,
    );
  }

  /// Called by [ChatNotifier.sendMessage] right after a user message is
  /// persisted. Runs every enabled `BlockTrigger.afterUser` block.
  Future<void> runAfterUserBlocks({
    required String charId,
    required ChatSession session,
    required Character character,
    required Persona? persona,
  }) async {
    final preset = _resolveActivePreset();
    if (preset == null) return;
    if (session.id.isEmpty || session.messages.isEmpty) return;
    final lastMessage = session.messages.last;
    if (lastMessage.role != 'user') {
      return;
    }
    final cancelToken = _startBlockRun();
    try {
      await _runChain(
        charId: charId,
        sessionId: session.id,
        messageId: lastMessage.id,
        swipeId: lastMessage.swipeId,
        agentSwipeId: -1,
        messages: session.messages,
        preset: preset,
        character: character,
        persona: persona,
        cancelToken: cancelToken,
        trigger: BlockTrigger.afterUser,
        where: _conditionsFor(session.messages, lastMessage.id, isUser: true),
      );
    } finally {
      _finishBlockRun(cancelToken);
      _refreshPanelForMessage(
        charId,
        session.id,
        lastMessage.id,
        lastMessage.swipeId,
        -1,
      );
    }
  }

  /// Runs the script blocks marked to answer to a swipe, after the user
  /// swiped [messages]' message to another variant or asked for a new one.
  ///
  /// Like the original, these run for their side effects only — variables,
  /// injections, sounds — and leave nothing in the panel.
  Future<void> runSwipeScripts({
    required String charId,
    required String sessionId,
    required List<ChatMessage> messages,
  }) => _runSideEffectScripts(
    charId: charId,
    sessionId: sessionId,
    messages: messages,
    reason: 'swipe',
    select: (b) => b.triggerOnSwipe,
  );

  /// Runs the script blocks marked to run when a generation starts, before
  /// the request goes out, so what they inject reaches this very reply.
  Future<void> runGenerationStartScripts({
    required String charId,
    required String sessionId,
    required List<ChatMessage> messages,
  }) => _runSideEffectScripts(
    charId: charId,
    sessionId: sessionId,
    messages: messages,
    reason: 'generation start',
    select: (b) => b.generationAfterCommands,
  );

  Future<void> _runSideEffectScripts({
    required String charId,
    required String sessionId,
    required List<ChatMessage> messages,
    required String reason,
    required bool Function(BlockConfig block) select,
  }) async {
    final preset = _resolveActivePreset();
    if (preset == null) return;
    final blocks =
        preset.blocks
            .where(
              (b) =>
                  b.enabled &&
                  !b.manualOnly &&
                  b.type == BlockType.script &&
                  select(b),
            )
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    for (final block in blocks) {
      // Only code the block carries runs here: asking the model to write a
      // script is a chain step with a panel to show it in, and STscript has
      // no interpreter in this app.
      if (block.source != BlockSource.carried ||
          block.scriptType != ScriptType.js) {
        debugPrint(
          '[ExtPostGen] $reason script "${block.name}" skipped: '
          'only carried JavaScript runs outside the chain',
        );
        continue;
      }
      try {
        await runJsBlock(
          charId: charId,
          sessionId: sessionId,
          block: block,
          contextMessages: messages,
        );
      } catch (e) {
        debugPrint('[ExtPostGen] $reason script "${block.name}" failed: $e');
      }
    }
  }

  /// Re-runs a single block for an already-existing message.
  Future<void> rerunBlock({
    required String blockId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required String sessionId,
    required String charId,
    required List<ChatMessage> messages,
    required Character character,
    required Persona? persona,
  }) async {
    final preset = _resolveActivePreset();
    if (preset == null) return;

    final blockConfig = preset.blocks.where((b) => b.id == blockId).firstOrNull;
    if (blockConfig == null) return;

    final side =
        messages.where((m) => m.id == messageId).firstOrNull?.role == 'user'
        ? BlockTrigger.afterUser
        : BlockTrigger.afterAssistant;
    Future<void> rebuildAccumulation() => _ref
        .read(extBlocksAccumulatorProvider)
        .rebuildForMessage(
          preset: preset,
          side: side,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          messages: messages,
        );

    // An accumulation block has no run of its own: running it again means
    // rebuilding the message's state from its updaters.
    if (blockConfig.type == BlockType.accumulation) {
      await rebuildAccumulation();
      _refreshPanelForMessage(
        charId,
        sessionId,
        messageId,
        swipeId,
        agentSwipeId,
      );
      return;
    }

    final cancelToken = _startBlockRun();

    final reuseBlockId = await _statusTracker.dedupeForConfig(
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      blockId: blockId,
    );

    try {
      final block = await _runSingleBlock(
        charId: charId,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        messages: messages,
        blockConfig: blockConfig,
        preset: preset,
        character: character,
        persona: persona,
        previousOutput: null,
        cancelToken: cancelToken,
        reuseBlockId: reuseBlockId,
      );

      if (block != null) {
        _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(block);
      }
      // A new generated result may carry a different updater.
      if (blockConfig.type == BlockType.generated && !cancelToken.isCancelled) {
        await rebuildAccumulation();
      }
    } finally {
      _finishBlockRun(cancelToken);
    }
    _refreshPanelForMessage(
      charId,
      sessionId,
      messageId,
      swipeId,
      agentSwipeId,
    );
  }

  /// Cancels any in-flight block generation for the current session.
  void cancelBlocks() {
    for (final token in _blocksCancelTokens.keys.toList()) {
      if (!token.isCancelled) token.cancel();
    }
  }

  CancelToken _startBlockRun() {
    final token = CancelToken();
    _blocksCancelTokens[token] = 1;
    return token;
  }

  void _holdBlockRun(CancelToken token) {
    _blocksCancelTokens[token] = (_blocksCancelTokens[token] ?? 0) + 1;
  }

  void _finishBlockRun(CancelToken token) {
    final holders = (_blocksCancelTokens[token] ?? 1) - 1;
    if (holders <= 0) {
      _blocksCancelTokens.remove(token);
    } else {
      _blocksCancelTokens[token] = holders;
    }
  }

  void _publishStreamingBlockContent({
    required String charId,
    required String sessionId,
    required String messageId,
    required InfoBlock placeholder,
    required String content,
    bool force = false,
  }) {
    _panelUpdater.publishStreamingContent(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      placeholder: placeholder,
      content: content,
      force: force,
    );
  }

  void Function(String)? _makeStreamHandler({
    required BlockConfig blockConfig,
    required String charId,
    required String sessionId,
    required String messageId,
    required InfoBlock placeholder,
  }) {
    return _panelUpdater.makeStreamHandler(
      blockConfig: blockConfig,
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      placeholder: placeholder,
    );
  }

  /// Redraws the pictures of a block that already has content, without asking
  /// the model for a new description.
  ///
  /// The block's type has nothing to do with it: what makes this possible is
  /// image tags in the stored content, so any generated block that produced a
  /// picture can be redrawn the same way.
  Future<void> rerunImageOnly({
    required String blockId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required String sessionId,
    required String charId,
    required Character character,
    required Persona? persona,
  }) async {
    final preset = _resolveActivePreset();
    if (preset == null) return;

    final blockConfig = preset.blocks.where((b) => b.id == blockId).firstOrNull;
    if (blockConfig == null) return;

    final rows = await _repo.getByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final existing = rows.where((b) => b.blockId == blockId).firstOrNull;
    if (existing == null || existing.content.isEmpty) return;

    final cancelToken = _startBlockRun();
    try {
      await BlockImageRenderer(
        ref: _ref,
        repo: _repo,
        publishStreamingBlockContent: _publishStreamingBlockContent,
      ).rerun(
        context: BlockContext(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          messages: const [],
          blockConfig: blockConfig,
          preset: preset,
          character: character,
          persona: persona,
          previousOutput: null,
          cancelToken: cancelToken,
          placeholderId: existing.id,
          placeholder: existing,
        ),
      );
    } finally {
      _finishBlockRun(cancelToken);
      _refreshPanelForMessage(
        charId,
        sessionId,
        messageId,
        swipeId,
        agentSwipeId,
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Chain execution
  // ─────────────────────────────────────────────────────────────────────────

  /// Runs one chain in the original extension's order: scripts marked
  /// "before", rewrites marked "before", the generated blocks, rewrites
  /// marked "after", scripts marked "after".
  ///
  /// Only carried scripts with no dependency take a phase. A script the model
  /// writes, or one chained to the block before it, keeps its place in the
  /// ordinary chain, where it has always run.
  Future<void> _runChain({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<ChatMessage> messages,
    required ExtensionPreset preset,
    required Character character,
    required Persona? persona,
    required CancelToken cancelToken,
    BlockTrigger trigger = BlockTrigger.afterAssistant,
    MainModelContextSnapshot? mainModelContextSnapshot,
    bool Function(BlockConfig block)? where,
  }) async {
    final eligible = _blockProcessor.selectBlocks(
      preset,
      trigger,
      where: where,
    );
    List<BlockConfig> phase(bool Function(BlockConfig b) test) =>
        eligible.where(test).toList();
    final beforeScripts = phase(
      (b) => isPhasedScript(b) && b.executionOrder == BlockRunOrder.before,
    );
    final afterScripts = phase(
      (b) => isPhasedScript(b) && b.executionOrder == BlockRunOrder.after,
    );
    final beforeRewrites = phase(
      (b) =>
          b.type == BlockType.rewrite &&
          b.generationOrder == BlockRunOrder.before,
    );
    final afterRewrites = phase(
      (b) =>
          b.type == BlockType.rewrite &&
          b.generationOrder == BlockRunOrder.after,
    );

    var current = messages;
    // Blocks of the ordinary chain that share one request, as the original
    // groups them.
    final groups = blockGroups(
      eligible.where(
        (b) =>
            b.type != BlockType.rewrite &&
            b.type != BlockType.accumulation &&
            !isPhasedScript(b),
      ),
    );
    Future<InfoBlock?> runOne(BlockConfig blockConfig, String? previous) =>
        _runSingleBlock(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          messages: current,
          blockConfig: blockConfig,
          preset: preset,
          character: character,
          persona: persona,
          previousOutput: previous,
          cancelToken: cancelToken,
          mainModelContextSnapshot: mainModelContextSnapshot,
          group: groups[blockConfig.id] ?? const [],
        );

    Future<void> runScripts(List<BlockConfig> scripts) async {
      for (final script in scripts) {
        if (cancelToken.isCancelled) return;
        final result = await runOne(script, null);
        if (result != null) {
          _ref
              .read(infoBlocksProvider(sessionId).notifier)
              .addOrReplace(result);
        }
      }
    }

    Future<void> runRewrites(List<BlockConfig> rewrites) async {
      if (rewrites.isEmpty || cancelToken.isCancelled) return;
      current = await _ref
          .read(extBlocksRewriteServiceProvider)
          .rewriteMessage(
            blocks: rewrites,
            charId: charId,
            sessionId: sessionId,
            messageId: messageId,
            messages: current,
            character: character,
            persona: persona,
            preset: preset,
            cancelToken: cancelToken,
          );
    }

    // The original's first accumulation pass reads the message as it came;
    // the state is rebuilt from the one before it, so a re-run applies each
    // update once.
    final accumulator = _ref.read(extBlocksAccumulatorProvider);
    final accumulators = ExtBlocksAccumulator.blocksFor(preset, trigger);
    final accumulationTarget = (
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      messages: messages,
    );
    if (accumulators.isNotEmpty) {
      await accumulator.resetForMessage(
        blocks: accumulators,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
      );
      await accumulator.accumulate(
        blocks: accumulators,
        target: accumulationTarget,
        text:
            messages.where((m) => m.id == messageId).firstOrNull?.content ?? '',
      );
    }

    await runScripts(beforeScripts);
    await runRewrites(beforeRewrites);
    if (cancelToken.isCancelled) return;

    await _blockProcessor.run(
      preset: preset,
      trigger: trigger,
      cancelToken: cancelToken,
      where: (b) =>
          (where?.call(b) ?? true) &&
          b.type != BlockType.rewrite &&
          b.type != BlockType.accumulation &&
          !isPhasedScript(b),
      runBlock: ({required blockConfig, required previousOutput}) =>
          runOne(blockConfig, previousOutput),
      onBlockComplete: (result) {
        _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(result);
      },
      onBackgroundStarted: (run) {
        // Stop still reaches a background block after its chain returned,
        // and the panel catches up once it lands.
        _holdBlockRun(cancelToken);
        unawaited(
          run.whenComplete(() {
            _finishBlockRun(cancelToken);
            _refreshPanelForMessage(
              charId,
              sessionId,
              messageId,
              swipeId,
              agentSwipeId,
            );
          }),
        );
      },
    );

    await runRewrites(afterRewrites);
    await runScripts(afterScripts);

    // The second pass reads the generated blocks now under the message.
    if (accumulators.isNotEmpty && !cancelToken.isCancelled) {
      await accumulator.accumulate(
        blocks: accumulators,
        target: accumulationTarget,
        text: await accumulator.generatedOutput(
          preset: preset,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
        ),
      );
    }
  }

  /// The keyword / period check for the message [messageId] in [messages].
  /// A message that is not in the list fails every check, so nothing runs
  /// against a message the chat no longer has.
  bool Function(BlockConfig block) _conditionsFor(
    List<ChatMessage> messages,
    String messageId, {
    required bool isUser,
  }) {
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return (_) => false;
    final text = messages[index].content;
    return (block) => blockConditionsMet(
      block,
      messageIndex: index,
      isUser: isUser,
      messageText: text,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Single block dispatch
  // ─────────────────────────────────────────────────────────────────────────

  Future<InfoBlock?> _runSingleBlock({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required ExtensionPreset preset,
    required Character character,
    required Persona? persona,
    required String? previousOutput,
    required CancelToken cancelToken,
    String? reuseBlockId,
    MainModelContextSnapshot? mainModelContextSnapshot,
    List<BlockConfig> group = const [],
  }) =>
      SingleBlockRunner(
        statusTracker: _statusTracker,
        refreshPanelForMessage: _refreshPanelForMessage,
        handlerFor: _handlerFor,
      ).run(
        charId: charId,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        messages: messages,
        blockConfig: blockConfig,
        preset: preset,
        character: character,
        persona: persona,
        previousOutput: previousOutput,
        cancelToken: cancelToken,
        reuseBlockId: reuseBlockId,
        mainModelContextSnapshot: mainModelContextSnapshot,
        group: group,
      );

  BlockHandler _handlerFor(BlockType type) {
    switch (type) {
      case BlockType.generated:
        return GeneratedBlockHandler(
          ref: _ref,
          repo: _repo,
          markBlockError: _markContextBlockError,
          refreshPanelForMessage: _refreshPanelForMessage,
          makeStreamHandler: _makeStreamHandler,
          publishStreamingBlockContent: _publishStreamingBlockContent,
        );
      case BlockType.script:
        return ScriptBlockHandler(
          repo: _repo,
          infoBlockService: _ref.read(infoBlockServiceProvider),
          markBlockError: _markContextBlockError,
          refreshPanelForMessage: _refreshPanelForMessage,
          makeStreamHandler: _makeStreamHandler,
          publishStreamingBlockContent: _publishStreamingBlockContent,
          executeJsScript: _executeContextJsScript,
        );
      case BlockType.rewrite:
        // Rewrites change the message in their own phase and never reach a
        // panel row; this only answers a stray manual run.
        return UnsupportedBlockHandler(
          markBlockError: _markContextBlockError,
          reason: 'Rewrite blocks rewrite the message and have no panel run.',
        );
      case BlockType.accumulation:
        // Accumulation state is rebuilt from updaters around the chain, never
        // by a panel run.
        return UnsupportedBlockHandler(
          markBlockError: _markContextBlockError,
          reason: 'Accumulation blocks are updated by their updater block.',
        );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // JS Runner
  // ─────────────────────────────────────────────────────────────────────────

  Future<InfoBlock?> _executeContextJsScript({
    required BlockContext context,
    required String script,
    String Function(String result)? panelContentBuilder,
  }) {
    return JsBlockExecutor(
      ref: _ref,
      repo: _repo,
      markBlockError: _markContextBlockError,
      refreshPanelForMessage: _refreshPanelForMessage,
    ).executeMessageScript(
      context: context,
      script: script,
      panelContentBuilder: panelContentBuilder,
    );
  }

  /// Public entry point for periodic ticks (no `InfoBlock` is created —
  /// periodic scripts are side-effect-only: write to `glaze.variables`,
  /// play audio, call `triggerGeneration`, etc.). Uses the headless
  /// engine when available; falls back to the visual bridge for the
  /// currently open chat. Returns the script result string or `null`
  /// when nothing was run.
  ///
  /// `contextMessages` is the message history to pass to the script.
  /// For periodic ticks this is typically the empty list — the script
  /// does not need the chat history, it just runs on a timer.
  Future<String?> runJsBlock({
    required String charId,
    required String sessionId,
    required BlockConfig block,
    required List<ChatMessage> contextMessages,
    bool Function()? isAuthorized,
  }) => PeriodicJsBlockRunner(ref: _ref).run(
    charId: charId,
    sessionId: sessionId,
    block: block,
    contextMessages: contextMessages,
    isAuthorized: isAuthorized,
  );
}

/// A script block that runs in its "before" or "after" phase rather than in
/// the ordinary chain: one carrying its own code and not chained to the block
/// before it, which is every script the original extension exports.
@visibleForTesting
bool isPhasedScript(BlockConfig block) =>
    block.type == BlockType.script &&
    block.source == BlockSource.carried &&
    !block.dependsOnPrevious;
