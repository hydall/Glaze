import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/llm/transport/llm_capture_context.dart';
import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/persona.dart';
import '../../../../core/services/image_storage_service.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/utils/error_format.dart';
import '../../../image_gen/image_gen_provider.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../models/block_config.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import 'block_context.dart';
import 'image_gen_block_handler.dart';
import 'infoblock_handler.dart';

class ImagePixelRenderer {
  const ImagePixelRenderer({
    required this.ref,
    required this.repo,
    required this.markBlockError,
    required this.refreshPanelForMessage,
    required this.publishStreamingBlockContent,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final BlockErrorMarker markBlockError;
  final PanelRefresher refreshPanelForMessage;
  final StreamingBlockPublisher publishStreamingBlockContent;

  Future<InfoBlock?> renderFromContext({
    required BlockContext context,
    required String sourceContent,
  }) {
    return render(
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

  Future<InfoBlock?> render({
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
  }) async {
    final imgGenSettings = ref.read(imageGenSettingsProvider).value;
    if (imgGenSettings == null || !imgGenSettings.enabled) {
      await repo.updateContent(placeholderId, sourceContent);
      await repo.updateStatus(placeholderId, BlockRunStatus.done);
      final done = placeholder.copyWith(
        content: sourceContent,
        status: BlockRunStatus.done,
      );
      ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(done);
      refreshPanelForMessage(
        charId,
        sessionId,
        messageId,
        swipeId,
        agentSwipeId,
      );
      return done;
    }

    final imageService = await ref
        .read(imageGenSettingsProvider.notifier)
        .getServiceAsync();
    final instructions = ImageTagMarkup.extractInstructionsFromImageContent(
      sourceContent,
    );
    if (instructions.isEmpty) {
      return markBlockError(
        context: _contextForError(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          blockConfig: blockConfig,
          character: character,
          persona: persona,
          placeholderId: placeholderId,
          placeholder: placeholder,
          cancelToken: cancelToken,
        ),
        errorMessage:
            'No image instruction found (expected [IMG:GEN] or [IMG:RESULT:…|json])',
      );
    }

    final rawPrompt = instructions.first['prompt'] as String? ?? '';
    if (rawPrompt.isEmpty) {
      return markBlockError(
        context: _contextForError(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          blockConfig: blockConfig,
          character: character,
          persona: persona,
          placeholderId: placeholderId,
          placeholder: placeholder,
          cancelToken: cancelToken,
        ),
        errorMessage: 'Image instruction JSON has empty prompt',
      );
    }

    publishStreamingBlockContent(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      placeholder: placeholder,
      content:
          '$sourceContent\n<p class="ext-block-image-pending">⏳ Генерация изображения…</p>',
      force: true,
    );

    try {
      List<String>? recentImageContexts;
      if (imgGenSettings.imageContextEnabled) {
        final sessionBlocks = await repo.getBySessionId(sessionId);
        final imageContents =
            sessionBlocks
                .where(
                  (b) =>
                      b.blockType == BlockType.imageGen.name &&
                      b.status == BlockRunStatus.done &&
                      b.id != placeholderId,
                )
                .toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        recentImageContexts = ImageTagMarkup.collectRecentImageResultPaths(
          imageContents.map((b) => b.content),
          maxPaths: 3,
        );
        if (recentImageContexts.isEmpty) recentImageContexts = null;
      }

      final style = instructions.first['style'] as String? ?? '';
      final cleanPrompt = rawPrompt.replaceFirst(
        RegExp(r'^SCENE_PROMPT:\s*'),
        '',
      );
      final instructionAspectRatio =
          instructions.first['aspect_ratio'] as String?;
      final instructionImageSize = instructions.first['image_size'] as String?;

      final imageBytes = await imageService.generateImage(
        settings: imgGenSettings,
        prompt: cleanPrompt,
        tagStyle: style,
        llmEndpoint: '',
        llmApiKey: '',
        llmModel: '',
        character: character,
        persona: persona,
        recentImageContexts: recentImageContexts,
        instructionAspectRatio: instructionAspectRatio,
        instructionImageSize: instructionImageSize,
        cancelToken: cancelToken,
        // Identity so the drawing lands in the turn that asked for it.
        captureContext: LlmCaptureContext(
          stage: 'image.generate',
          sessionId: sessionId,
          messageId: messageId,
        ),
      );

      if (cancelToken.isCancelled) {
        await repo.updateStatus(placeholderId, BlockRunStatus.stopped);
        return placeholder.copyWith(status: BlockRunStatus.stopped);
      }

      final storage = await ref.read(imageStorageProvider.future);
      final dir = Directory(p.join(storage.baseDir, 'generated'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final extension = imageExtensionForBytes(imageBytes);
      final filename =
          'extblock_${DateTime.now().millisecondsSinceEpoch}.$extension';
      final filePath = p.join(dir.path, filename);
      await File(filePath).writeAsBytes(imageBytes);
      // Stored relative to the Glaze data root, so the block keeps its picture
      // when that root moves — same reason as _saveGeneratedImage.
      final storedPath = p.url.join('generated', filename);

      // The block's first image block, whatever state it is in: a pending tag
      // on the first run, and the finished block itself on a rerun — which is
      // what makes the new picture land in the block that already has one
      // instead of being dropped for want of a pending tag.
      final content = ImageTagMarkup.scanImageBlocks(sourceContent).isEmpty
          ? sourceContent
          : ImageTagMarkup.replaceImageBlockWithResult(
              sourceContent,
              0,
              storedPath,
            );
      await repo.updateContent(placeholderId, content);
      await repo.updateStatus(placeholderId, BlockRunStatus.done);

      final done = InfoBlock(
        id: placeholderId,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        blockId: blockConfig.id,
        blockName: blockConfig.name,
        blockType: blockConfig.type.name,
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: blockConfig.order,
        status: BlockRunStatus.done,
      );
      ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(done);
      refreshPanelForMessage(
        charId,
        sessionId,
        messageId,
        swipeId,
        agentSwipeId,
      );
      return done;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        await repo.updateStatus(placeholderId, BlockRunStatus.stopped);
        return placeholder.copyWith(status: BlockRunStatus.stopped);
      }
      return markBlockError(
        context: _contextForError(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          blockConfig: blockConfig,
          character: character,
          persona: persona,
          placeholderId: placeholderId,
          placeholder: placeholder,
          cancelToken: cancelToken,
        ),
        errorMessage: formatError(e),
      );
    } catch (e) {
      return markBlockError(
        context: _contextForError(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          blockConfig: blockConfig,
          character: character,
          persona: persona,
          placeholderId: placeholderId,
          placeholder: placeholder,
          cancelToken: cancelToken,
        ),
        errorMessage: formatError(e),
      );
    }
  }

  BlockContext _contextForError({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required BlockConfig blockConfig,
    required Character character,
    required Persona? persona,
    required String placeholderId,
    required InfoBlock placeholder,
    required CancelToken cancelToken,
  }) {
    return BlockContext(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      messages: const [],
      blockConfig: blockConfig,
      preset: null,
      character: character,
      persona: persona,
      previousOutput: null,
      cancelToken: cancelToken,
      placeholderId: placeholderId,
      placeholder: placeholder,
    );
  }
}
