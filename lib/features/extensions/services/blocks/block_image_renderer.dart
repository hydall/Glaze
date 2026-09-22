import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../../../core/models/api_config.dart';
import '../../../../core/utils/error_format.dart';
import '../../../image_gen/image_gen_provider.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../../settings/api_list_provider.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import 'block_context.dart';
import 'block_handler.dart';

/// Draws the pictures a block's content asks for.
///
/// This is the chat's own image pipeline, not a copy of it: the content goes
/// through [ImageGenService.processMessageImages], the same call that turns
/// `[IMG:GEN]` in a character's reply into a picture. A block therefore gets
/// what a message has always got and what the old block-only renderer never
/// did — every tag in the content rather than just the first, a retryable
/// error card in place of a tag that failed instead of the whole block going
/// red, concurrent generation when the settings ask for it, and the reference
/// images and `useSameEndpoint` wiring the shared service resolves.
///
/// Nothing here looks at the block's type. A block draws pictures because its
/// content carries image tags, exactly as a message does.
class BlockImageRenderer {
  const BlockImageRenderer({
    required this.ref,
    required this.repo,
    required this.publishStreamingBlockContent,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final StreamingBlockPublisher publishStreamingBlockContent;

  /// Whether [content] has anything for this renderer to do.
  static bool hasWork(String content) => ImageTagMarkup.hasImageGenTags(content);

  /// Returns [sourceContent] with its image tags resolved, or unchanged when
  /// there were none.
  ///
  /// Never throws: a provider failure comes back as an error card inside the
  /// text, so the block itself still finishes and the reader can retry the one
  /// picture that failed.
  Future<String> render({
    required BlockContext context,
    required String sourceContent,
  }) async {
    if (!hasWork(sourceContent)) return sourceContent;

    final settings = ref.read(imageGenSettingsProvider).value;
    if (settings == null) return sourceContent;

    final service = await ref
        .read(imageGenSettingsProvider.notifier)
        .getServiceAsync();
    final apiConfig = await _apiConfigFor(context);

    try {
      return await service.processMessageImages(
        text: sourceContent,
        settings: settings,
        // Empty here used to disable the "use the chat's endpoint" setting for
        // blocks without saying so; the block's own connection is what that
        // setting means when an ext block is the one drawing.
        llmEndpoint: apiConfig?.endpoint ?? '',
        llmApiKey: apiConfig?.apiKey ?? '',
        llmModel: apiConfig?.model ?? '',
        character: context.character,
        persona: context.persona,
        recentImageContexts: await _recentImageContexts(context),
        cancelToken: context.cancelToken,
        onUpdate: (updated) => publishStreamingBlockContent(
          charId: context.charId,
          sessionId: context.sessionId,
          messageId: context.messageId,
          placeholder: context.placeholder,
          content: updated,
          force: true,
        ),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return sourceContent;
      return ImageTagMarkup.replaceTagWithError(
        sourceContent,
        0,
        formatError(e),
      );
    } catch (e) {
      return ImageTagMarkup.replaceTagWithError(sourceContent, 0, formatError(e));
    }
  }

  /// Re-draws the pictures of a block that already has some.
  ///
  /// Used by the panel's "Image" control, which repeats only the drawing and
  /// never asks the model for a new description. [blockIndex] narrows it to the
  /// one picture the reader tapped.
  Future<InfoBlock?> rerun({
    required BlockContext context,
    int? blockIndex,
  }) async {
    final existing = context.placeholder.content;
    if (existing.isEmpty) return null;

    final pending = blockIndex != null
        ? ImageTagMarkup.resetImageBlockAt(existing, blockIndex)
        : ImageTagMarkup.resetErrorTags(existing);
    // Unchanged text means the content addressed nothing that could be redrawn.
    if (pending == existing && !hasWork(existing)) return null;

    await repo.updateStatus(context.placeholderId, BlockRunStatus.running);
    final running = context.placeholder.copyWith(
      content: pending,
      status: BlockRunStatus.running,
    );
    ref.read(infoBlocksProvider(context.sessionId).notifier).addOrReplace(running);

    final rendered = await render(context: context, sourceContent: pending);

    if (context.cancelToken.isCancelled) {
      await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
      return running.copyWith(status: BlockRunStatus.stopped);
    }

    await repo.updateContent(context.placeholderId, rendered);
    await repo.updateStatus(context.placeholderId, BlockRunStatus.done);
    final done = running.copyWith(
      content: rendered,
      status: BlockRunStatus.done,
    );
    ref.read(infoBlocksProvider(context.sessionId).notifier).addOrReplace(done);
    return done;
  }

  /// The block's own connection, falling back to the chat's active one.
  Future<ApiConfig?> _apiConfigFor(BlockContext context) async {
    final configs = await ref.read(apiListProvider.future);
    if (configs.isEmpty) return null;
    final blockId = context.blockConfig.apiConfigId;
    if (blockId.isNotEmpty) {
      final own = configs.where((c) => c.id == blockId).firstOrNull;
      if (own != null) return own;
    }
    final activeId = ref.read(activeApiPresetIdProvider);
    return configs.where((c) => c.id == activeId).firstOrNull ?? configs.first;
  }

  /// Images this session's other blocks already produced, newest last, so a
  /// provider that takes reference images keeps the scene consistent.
  Future<List<String>?> _recentImageContexts(BlockContext context) async {
    final settings = ref.read(imageGenSettingsProvider).value;
    if (settings == null || !settings.imageContextEnabled) return null;

    final rows = await repo.getBySessionId(context.sessionId);
    final done =
        rows
            .where(
              (b) =>
                  b.status == BlockRunStatus.done &&
                  b.id != context.placeholderId,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final paths = ImageTagMarkup.collectRecentImageResultPaths(
      done.map((b) => b.content),
      maxPaths: 3,
    );
    return paths.isEmpty ? null : paths;
  }
}
