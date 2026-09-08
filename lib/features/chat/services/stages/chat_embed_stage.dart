import 'package:flutter/foundation.dart';

import '../../../../core/llm/memory_injection_service.dart'
    show chatMessageEmbeddingServiceProvider;
import '../../../../core/models/chat_message.dart';
import '../../../../core/state/lorebook_embedding_provider.dart'
    show embeddingConfigProvider;
import 'stage_context.dart';

/// Stage 3.5: embed raw chat-message chunks (fire-and-forget, best-effort
/// insurance for the lossy MemoryBook compression).
///
/// Idempotent via textHash — chunks whose content has not changed since
/// the last embedding pass are skipped. Filters to visible user+assistant
/// messages, groups them into fixed-size chunks (default 5), and stores
/// one embedding row per chunk under `sourceType='chat_message'`. The
/// [MessageRecallService] cosine-searches against these rows on the next
/// generation and injects top-K chunks as `<recalled_messages>` in the
/// prompt.
///
/// Rationale (patch #3): chunk=5 messages → EmbeddingRepo with
/// `sourceType='chat_message'` → cosine ≥ 0.25, top-K=8 → `<recalled_messages>`.
/// Lossless backstop for the lossy MemoryBook compression. ADR: if mobile
/// latency / binary size becomes prohibitive, feature-flag `runMemoryRecall`
/// per-chat (default off on mobile), lazy-load the embedder binary on first
/// request, or drop Recall entirely — MemoryBook + context window already
/// covers ~80% of cases.
///
/// Staleness guard: aborts early if a newer generation has started. The
/// underlying [ChatMessageEmbeddingService] wraps all errors in try/catch
/// and records them via `putEmbeddingError` so the next run can retry —
/// this method never throws to the caller.
class ChatEmbedStage {
  final StageContext ctx;

  ChatEmbedStage(this.ctx);

  Future<void> run({
    required String sessionId,
    required List<ChatMessage> messages,
    required int genId,
  }) async {
    try {
      if (!ctx.abortHandler.isCurrentGen(genId)) return;
      final config = ctx.ref.read(embeddingConfigProvider);
      if (config.endpoint.isEmpty) return;
      await ctx.ref
          .read(chatMessageEmbeddingServiceProvider)
          .indexSessionMessages(
            sessionId: sessionId,
            messages: messages,
            config: config,
          );
    } catch (e) {
      debugPrint('[ChatEmbedStage] failed session=$sessionId error=$e');
    }
  }
}
