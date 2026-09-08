import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/info_blocks_repository.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/llm/prompt/main_model_context_snapshot.dart';
import '../../../core/state/db_provider.dart';
import '../models/block_config.dart';
import '../models/extension_preset.dart';
import '../models/info_block.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import '../providers/info_blocks_provider.dart';
import 'info_block_service.dart';
import 'blocks/block_processor.dart';
import 'blocks/block_context.dart';
import 'blocks/block_handler.dart';
import 'blocks/block_panel_updater.dart';
import 'blocks/image_gen_block_handler.dart';
import 'blocks/image_only_rerunner.dart';
import 'blocks/image_pixel_renderer.dart';
import 'blocks/interactive_block_handler.dart';
import 'blocks/js_block_executor.dart';
import 'blocks/js_runner_block_handler.dart';
import 'blocks/infoblock_handler.dart';
import 'blocks/block_status_tracker.dart';
import 'blocks/periodic_js_block_runner.dart';
import 'blocks/single_block_runner.dart';

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

  /// Active cancel tokens for block runs. Multiple chains can overlap
  /// (for example, an afterAssistant image block and afterUser blocks from the
  /// next message), so a single mutable token would orphan older runs.
  final Set<CancelToken> _blocksCancelTokens = <CancelToken>{};

  final BlockProcessor _blockProcessor = const BlockProcessor();

  InfoBlocksRepository get _repo =>
      InfoBlocksRepository(_ref.read(appDbProvider));

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
  }) async {
    final preset = _resolveActivePreset();
    if (preset == null) return false;
    final blocks = _blockProcessor.selectBlocks(
      preset,
      BlockTrigger.afterAssistant,
    );
    if (blocks.isEmpty) return false;

    onStarted?.call();

    if (clearExisting) {
      await _ref
          .read(infoBlocksProvider(sessionId).notifier)
          .deleteByMessageId(
            messageId,
            swipeId: swipeId,
            agentSwipeId: agentSwipeId,
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

  ExtensionPreset? _resolveActivePreset() {
    final settings = _ref.read(extensionsSettingsProvider);
    if (!settings.enabled) {
      return null;
    }
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
    for (final token in _blocksCancelTokens.toList()) {
      if (!token.isCancelled) token.cancel();
    }
  }

  CancelToken _startBlockRun() {
    final token = CancelToken();
    _blocksCancelTokens.add(token);
    return token;
  }

  void _finishBlockRun(CancelToken token) {
    _blocksCancelTokens.remove(token);
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

  /// Re-runs only the Image Gen step for an existing image ext block (keeps agent HTML).
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

    final cancelToken = _startBlockRun();

    try {
      await ImageOnlyRerunner(
        ref: _ref,
        repo: _repo,
        refreshPanelForMessage: _refreshPanelForMessage,
        renderImagePixels: _renderImagePixels,
      ).rerun(
        blockId: blockId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        sessionId: sessionId,
        charId: charId,
        character: character,
        persona: persona,
        blocks: preset.blocks,
        cancelToken: cancelToken,
      );
    } finally {
      _finishBlockRun(cancelToken);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Chain execution
  // ─────────────────────────────────────────────────────────────────────────

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
  }) async {
    await _blockProcessor.run(
      preset: preset,
      trigger: trigger,
      cancelToken: cancelToken,
      runBlock: ({required blockConfig, required previousOutput}) {
        return _runSingleBlock(
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
          mainModelContextSnapshot: mainModelContextSnapshot,
        );
      },
      onBlockComplete: (result) {
        _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(result);
      },
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
      );

  BlockHandler _handlerFor(BlockType type) {
    switch (type) {
      case BlockType.infoblock:
        return InfoblockHandler(
          ref: _ref,
          repo: _repo,
          markBlockError: _markContextBlockError,
          refreshPanelForMessage: _refreshPanelForMessage,
          makeStreamHandler: _makeStreamHandler,
        );
      case BlockType.imageGen:
        return ImageGenBlockHandler(
          ref: _ref,
          repo: _repo,
          markBlockError: _markContextBlockError,
          makeStreamHandler: _makeStreamHandler,
          publishStreamingBlockContent: _publishStreamingBlockContent,
          renderImagePixels: _renderContextImagePixels,
        );
      case BlockType.jsRunner:
        return JsRunnerBlockHandler(
          repo: _repo,
          infoBlockService: _ref.read(infoBlockServiceProvider),
          markBlockError: _markContextBlockError,
          refreshPanelForMessage: _refreshPanelForMessage,
          makeStreamHandler: _makeStreamHandler,
          publishStreamingBlockContent: _publishStreamingBlockContent,
          executeJsScript: _executeContextJsScript,
        );
      case BlockType.interactive:
        return InteractiveBlockHandler(
          ref: _ref,
          repo: _repo,
          markBlockError: _markContextBlockError,
          refreshPanelForMessage: _refreshPanelForMessage,
          publishStreamingBlockContent: _publishStreamingBlockContent,
        );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Image gen
  // ─────────────────────────────────────────────────────────────────────────

  Future<InfoBlock?> _renderContextImagePixels({
    required BlockContext context,
    required String sourceContent,
  }) {
    return _renderImagePixels(
      charId: context.charId,
      sessionId: context.sessionId,
      messageId: context.messageId,
      swipeId: context.swipeId,
      agentSwipeId: context.agentSwipeId,
      blockConfig: context.blockConfig,
      character: context.character,
      persona: context.persona,
      sourceContent: sourceContent,
      placeholderId: context.placeholderId,
      placeholder: context.placeholder,
      cancelToken: context.cancelToken,
    );
  }

  Future<InfoBlock?> _renderImagePixels({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required BlockConfig blockConfig,
    required Character character,
    required Persona? persona,
    required String sourceContent,
    required String placeholderId,
    required InfoBlock placeholder,
    required CancelToken cancelToken,
  }) {
    return ImagePixelRenderer(
      ref: _ref,
      repo: _repo,
      markBlockError: _markContextBlockError,
      refreshPanelForMessage: _refreshPanelForMessage,
      publishStreamingBlockContent: _publishStreamingBlockContent,
    ).render(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      blockConfig: blockConfig,
      character: character,
      persona: persona,
      sourceContent: sourceContent,
      placeholderId: placeholderId,
      placeholder: placeholder,
      cancelToken: cancelToken,
    );
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
