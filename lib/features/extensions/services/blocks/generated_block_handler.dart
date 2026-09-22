import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../models/block_config.dart';
import '../../models/block_modes.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import '../info_block_service.dart';
import '../macro_expander.dart';
import '../panel_host_service.dart';
import 'block_context.dart';
import 'block_handler.dart';
import 'block_image_renderer.dart';

/// Runs a [BlockType.generated] block: everything that produces content for
/// the reader rather than executing code.
///
/// This one handler replaced three that differed only in what they did with
/// the reply — the infoblock's card, the image block's picture, the
/// interactive block's iframe. Each of those is now a step every generated
/// block goes through, skipped when the block gives it nothing to do:
///
/// 1. the content is generated, or taken from [BlockConfig.staticContent]
///    when [BlockConfig.source] says the block carries its own;
/// 2. any image tag in it is drawn, by the same pipeline a chat message uses;
/// 3. the result is shown as [BlockConfig.render] asks — a card, or a
///    sandboxed panel.
///
/// So an infoblock that happens to ask for a picture gets one, and a panel
/// whose markup is written by hand needs no model. Neither was expressible
/// while the three were separate types.
class GeneratedBlockHandler implements BlockHandler {
  const GeneratedBlockHandler({
    required this.ref,
    required this.repo,
    required this.markBlockError,
    required this.refreshPanelForMessage,
    required this.makeStreamHandler,
    required this.publishStreamingBlockContent,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final BlockErrorMarker markBlockError;
  final PanelRefresher refreshPanelForMessage;
  final StreamHandlerFactory makeStreamHandler;
  final StreamingBlockPublisher publishStreamingBlockContent;

  @override
  Future<InfoBlock?> handle(BlockContext context) async {
    if (context.cancelToken.isCancelled) return _stopped(context);

    final blockConfig = context.blockConfig;

    String content;
    if (blockConfig.source == BlockSource.carried) {
      final carried = blockConfig.staticContent.trim();
      // Nothing to show. Finishing empty rather than erroring keeps an
      // unconfigured block out of the reader's way.
      if (carried.isEmpty) return _finishEmpty(context);
      content = carried;
    } else {
      if (blockConfig.prompt.trim().isEmpty) return _finishEmpty(context);
      final generated = await ref
          .read(infoBlockServiceProvider)
          .generateSingleBlockContent(
            sessionId: context.sessionId,
            messageId: context.messageId,
            messages: context.messages,
            blockConfig: blockConfig,
            character: context.character,
            persona: context.persona?.name,
            personaPrompt: context.persona?.prompt,
            previousOutput: context.previousOutput,
            contextPolicy: blockConfig.contextPolicy,
            mainModelContextSnapshot: context.mainModelContextSnapshot,
            personaModel: context.persona,
            preset: context.preset,
            swipeId: context.swipeId,
            cancelToken: context.cancelToken,
            onStreamUpdate: makeStreamHandler(
              blockConfig: blockConfig,
              charId: context.charId,
              sessionId: context.sessionId,
              messageId: context.messageId,
              placeholder: context.placeholder,
            ),
          );

      if (context.cancelToken.isCancelled) return _stopped(context);

      if (generated.error != null) {
        return markBlockError(context: context, errorMessage: generated.error!);
      }
      final text = generated.content;
      if (text == null || text.isEmpty) {
        return markBlockError(
          context: context,
          errorMessage: 'Generation produced empty content',
        );
      }
      content = text;
      _publish(context, content);
    }

    // Pictures, if the content asks for any. A block with no image tag never
    // touches the image pipeline, so this costs an ordinary infoblock nothing.
    content = await BlockImageRenderer(
      ref: ref,
      repo: repo,
      publishStreamingBlockContent: publishStreamingBlockContent,
    ).render(context: context, sourceContent: content);

    if (context.cancelToken.isCancelled) return _stopped(context);

    if (blockConfig.render == BlockRender.panel) {
      final opened = await _openPanel(context, content);
      if (!opened) {
        return markBlockError(
          context: context,
          errorMessage:
              'Interactive panel host did not open a panel (no chat bridge?)',
        );
      }
    }

    return _finish(context, content);
  }

  /// Hands the block's markup to the sandboxed iframe host.
  ///
  /// Macros are expanded here rather than at render time: the panel's HTML
  /// goes straight into the iframe and never passes the panel builder, so
  /// `{{char}}` inside it used to reach the reader literally.
  Future<bool> _openPanel(BlockContext context, String html) async {
    final expanded = expand(
      html,
      MacroContext(
        character: context.character,
        persona: context.persona?.name,
      ),
    );
    final opened = await ref
        .read(panelHostServiceProvider)
        .openPanel(
          charId: context.charId,
          messageId: context.messageId,
          html: expanded,
          options: {
            'title': context.blockConfig.name,
            'minHeight': context.blockConfig.panelMinHeight,
          },
        );
    return opened != null;
  }

  void _publish(BlockContext context, String content) {
    publishStreamingBlockContent(
      charId: context.charId,
      sessionId: context.sessionId,
      messageId: context.messageId,
      placeholder: context.placeholder,
      content: content,
      force: true,
    );
  }

  Future<InfoBlock> _finish(BlockContext context, String content) async {
    await repo.updateContent(context.placeholderId, content);
    await repo.updateStatus(context.placeholderId, BlockRunStatus.done);
    return _settle(
      context,
      context.placeholder.copyWith(
        content: content,
        status: BlockRunStatus.done,
      ),
    );
  }

  Future<InfoBlock> _finishEmpty(BlockContext context) async {
    await repo.updateStatus(context.placeholderId, BlockRunStatus.done);
    return _settle(
      context,
      context.placeholder.copyWith(status: BlockRunStatus.done),
    );
  }

  Future<InfoBlock> _stopped(BlockContext context) async {
    await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
    return _settle(
      context,
      context.placeholder.copyWith(status: BlockRunStatus.stopped),
    );
  }

  Future<InfoBlock> _settle(BlockContext context, InfoBlock block) async {
    ref.read(infoBlocksProvider(context.sessionId).notifier).addOrReplace(block);
    refreshPanelForMessage(
      context.charId,
      context.sessionId,
      context.messageId,
      context.swipeId,
      context.agentSwipeId,
    );
    return block;
  }
}
