import 'package:flutter/foundation.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../info_block_service.dart';
import '../js_script_extractor.dart';
import 'block_context.dart';
import 'block_handler.dart';
import 'image_gen_block_handler.dart';
import 'infoblock_handler.dart';

typedef JsScriptExecutor =
    Future<InfoBlock?> Function({
      required BlockContext context,
      required String script,
      String Function(String result)? panelContentBuilder,
    });

class JsRunnerBlockHandler implements BlockHandler {
  const JsRunnerBlockHandler({
    required this.repo,
    required this.infoBlockService,
    required this.markBlockError,
    required this.refreshPanelForMessage,
    required this.makeStreamHandler,
    required this.publishStreamingBlockContent,
    required this.executeJsScript,
  });

  final InfoBlocksRepository repo;
  final InfoBlockService infoBlockService;
  final BlockErrorMarker markBlockError;
  final PanelRefresher refreshPanelForMessage;
  final StreamHandlerFactory makeStreamHandler;
  final StreamingBlockPublisher publishStreamingBlockContent;
  final JsScriptExecutor executeJsScript;

  @override
  Future<InfoBlock?> handle(BlockContext context) async {
    final blockConfig = context.blockConfig;
    final placeholder = context.placeholder;
    if (context.cancelToken.isCancelled) {
      await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
      return placeholder.copyWith(status: BlockRunStatus.stopped);
    }

    final prompt = blockConfig.prompt.trim();
    final staticScript = blockConfig.script.trim();

    // Legacy: hand-written script without LLM prompt.
    if (prompt.isEmpty && staticScript.isNotEmpty) {
      return executeJsScript(context: context, script: staticScript);
    }

    if (prompt.isEmpty) {
      debugPrint(
        '[ExtPostGen] jsRunner "${blockConfig.name}" - prompt is empty',
      );
      await repo.updateStatus(context.placeholderId, BlockRunStatus.done);
      refreshPanelForMessage(
        context.charId,
        context.sessionId,
        context.messageId,
        context.swipeId,
        context.agentSwipeId,
      );
      return placeholder.copyWith(status: BlockRunStatus.done);
    }

    debugPrint('[ExtPostGen] _runJsRunner START: name="${blockConfig.name}"');

    final generated = await infoBlockService.generateSingleBlockContent(
      sessionId: context.sessionId,
      messageId: context.messageId,
      messages: context.messages,
      blockConfig: blockConfig,
      character: context.character,
      persona: context.persona?.name,
      previousOutput: context.previousOutput,
      contextPolicy: blockConfig.contextPolicy,
      mainModelContextSnapshot: context.mainModelContextSnapshot,
      personaModel: context.persona,
      swipeId: context.swipeId,
      cancelToken: context.cancelToken,
      onStreamUpdate: makeStreamHandler(
        blockConfig: blockConfig,
        charId: context.charId,
        sessionId: context.sessionId,
        messageId: context.messageId,
        placeholder: placeholder,
      ),
    );

    if (context.cancelToken.isCancelled) {
      await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
      return placeholder.copyWith(status: BlockRunStatus.stopped);
    }

    if (generated.error != null || generated.content == null) {
      return markBlockError(
        context: context,
        errorMessage: generated.error ?? 'JS agent returned empty response',
      );
    }

    final agentOutput = generated.content!;
    publishStreamingBlockContent(
      charId: context.charId,
      sessionId: context.sessionId,
      messageId: context.messageId,
      placeholder: placeholder,
      content: agentOutput,
      force: true,
    );

    final script = JsScriptExtractor.extractFromLlmResponse(agentOutput);
    if (script == null || script.isEmpty) {
      return markBlockError(
        context: context,
        errorMessage:
            'No JavaScript found in LLM response (expected ```js ... ``` fence or raw code)',
      );
    }

    publishStreamingBlockContent(
      charId: context.charId,
      sessionId: context.sessionId,
      messageId: context.messageId,
      placeholder: placeholder,
      content:
          '$agentOutput\n<p class="ext-block-js-pending">⏳ Выполнение JS…</p>',
      force: true,
    );

    return executeJsScript(
      context: context,
      script: script,
      panelContentBuilder: (result) =>
          JsScriptExtractor.formatPanelContent(script: script, result: result),
    );
  }
}
