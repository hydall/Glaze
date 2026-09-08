import '../db/repositories/embedding_repo.dart';
import '../models/chat_message.dart';
import '../utils/cast_helpers.dart';
import 'embedding_service.dart';

/// Indexes raw chat-message content into the `embeddings` table under
/// `sourceType: 'chat_message'`. Each chunk is [chunkSize] consecutive
/// messages (default 5, mirroring Marinara's `CHUNK_SIZE = 5` in
/// `memory-recall.ts`), formatted as:
///
/// ```
/// Name: content
///
/// Name: content
/// ...
/// ```
///
/// Per chunk: one embedding row keyed by `entryId = '${sessionId}_${i}'`
/// where `i` is the chunk index, `sourceId = sessionId`. This lets
/// [MessageRecallService] cosine-search against the current user message
/// and return top-K raw message chunks as a lossless backstop for the
/// lossy MemoryBook compression.
///
/// Rationale (patch #3): chunk=5 messages → EmbeddingRepo with
/// `sourceType='chat_message'`, cosine ≥ 0.25, top-K=8, injected as
/// `<recalled_messages>`. Fire-and-forget after each generation.
/// ADR: if mobile latency / binary size becomes prohibitive, feature-flag
/// `runMemoryRecall` per-chat (default off on mobile), lazy-load the embedder
/// binary on first request, or drop Recall entirely — MemoryBook + context
/// window already covers ~80% of cases. Marinara itself keeps Recall parallel
/// to Lorebook + Summary as insurance against lossy compression; without it,
/// agent-filtered "unimportant" details are unrecoverable when they later matter.
class ChatMessageEmbeddingService {
  final EmbeddingRepo _repo;
  final EmbeddingService _embeddingService;

  /// Number of consecutive messages per chunk. Marinara uses 5; we match.
  static const int defaultChunkSize = 5;

  ChatMessageEmbeddingService(this._repo, this._embeddingService);

  /// Embeds the chat messages of [sessionId] as fixed-size chunks of
  /// [chunkSize] consecutive messages. Idempotent: chunks whose textHash
  /// matches the stored row are skipped.
  ///
  /// Filters: only `user` and `assistant` messages with non-empty `id` and
  /// non-empty `content`; excludes `isHidden` and `isTyping` messages
  /// (same visibility filter as vector-search history in
  /// `prompt_payload_builder.dart`).
  ///
  /// Fire-and-forget at the call site — wraps all errors in try/catch and
  /// records them via [EmbeddingRepo.putEmbeddingError] so the next run can
  /// retry. Never throws to the caller.
  Future<void> indexSessionMessages({
    required String sessionId,
    required List<ChatMessage> messages,
    required EmbeddingConfig config,
    int chunkSize = defaultChunkSize,
  }) async {
    if (config.endpoint.isEmpty) return;
    if (chunkSize < 1) chunkSize = 1;

    final eligible = messages
        .where(
          (m) =>
              !m.isTyping &&
              !m.isHidden &&
              !m.isError &&
              m.id.isNotEmpty &&
              m.content.trim().isNotEmpty &&
              (m.role == 'user' || m.role == 'assistant'),
        )
        .toList();
    final chunks = <_MessageChunk>[];
    for (int i = 0; i + chunkSize <= eligible.length; i += chunkSize) {
      final slice = eligible.sublist(i, i + chunkSize);
      final text = _formatChunk(slice);
      chunks.add(
        _MessageChunk(
          index: i ~/ chunkSize,
          text: text,
          messageIds: slice.map((m) => m.id).toList(),
        ),
      );
    }
    final existingRows = await _repo.getBySource('chat_message', sessionId);
    final existingByEntryId = {
      for (final row in existingRows) row.entryId: row,
    };
    final currentEntryIds = {
      for (final chunk in chunks) '${sessionId}_${chunk.index}',
    };
    final staleEntryIds = existingByEntryId.keys
        .where((entryId) => !currentEntryIds.contains(entryId))
        .toList();
    if (staleEntryIds.isNotEmpty) {
      await _repo.deleteBySourceAndEntryIds(
        'chat_message',
        sessionId,
        staleEntryIds,
      );
    }
    if (chunks.isEmpty) return;

    for (final chunk in chunks) {
      final entryId = '${sessionId}_${chunk.index}';
      final textHash = computeHash(chunk.text);

      try {
        final existing = existingByEntryId[entryId];
        if (existing != null &&
            existing.textHash == textHash &&
            _repo.hasUsableVectors(existing) &&
            existing.errorJson == null) {
          continue;
        }

        final embedded = await _embeddingService.getEmbeddingsWithChunks([
          chunk.text,
        ], config);
        final vectors = embedded.map((c) => c.vector).toList();
        if (vectors.isEmpty) continue;

        await _repo.putEmbeddingVector(
          entryId: entryId,
          sourceType: 'chat_message',
          sourceId: sessionId,
          vectors: vectors,
          textHash: textHash,
          retrievalMetadata: embeddingMetadataForConfig(
            config,
            vectors,
            // Same shape as MemoryEmbeddingService — list of {index, text}
            // so MessageRecallService can extract the matched chunk text
            // via the standard _decodeChunkTexts path.
            chunks: [
              for (int i = 0; i < embedded.length; i++)
                {'index': i, 'text': embedded[i].text},
            ],
            // Provenance for debugging and orphan-cleanup tools.
            extra: {
              'messageIds': chunk.messageIds,
              'chunkIndex': chunk.index,
              'chunkCount': chunks.length,
              'chunkSize': chunkSize,
            },
          ),
        );
      } on RateLimitException {
        await _repo.putEmbeddingError(
          entryId: entryId,
          sourceType: 'chat_message',
          sourceId: sessionId,
          textHash: textHash,
          error: const {
            'type': 'rate_limit',
            'message': 'Rate limited, deferred',
            'retryable': true,
          },
          retrievalMetadata: embeddingMetadataForConfig(
            config,
            const [],
            extra: {'messageIds': chunk.messageIds, 'chunkIndex': chunk.index},
          ),
        );
        // Stop the loop — rate limits apply to the whole endpoint.
        return;
      } catch (e) {
        await _repo.putEmbeddingError(
          entryId: entryId,
          sourceType: 'chat_message',
          sourceId: sessionId,
          textHash: textHash,
          error: {
            'type': 'api_error',
            'message': e.toString(),
            'retryable': true,
          },
          retrievalMetadata: embeddingMetadataForConfig(
            config,
            const [],
            extra: {'messageIds': chunk.messageIds, 'chunkIndex': chunk.index},
          ),
        );
      }
    }
  }

  /// Removes all chunk rows for [sessionId]. Called when a session is
  /// deleted to avoid orphan embeddings.
  Future<void> deleteSessionIndex(String sessionId) async {
    await _repo.deleteBySource('chat_message', sessionId);
  }

  /// Removes all `chat_message` embeddings (every session). Used by the
  /// "clear all vector data" admin action if one is added later.
  Future<void> deleteAllChatMessageIndexes() async {
    await _repo.deleteBySourceType('chat_message');
  }

  String _formatChunk(List<ChatMessage> slice) {
    // Marinara format: "Name: content\n\nName: content". We use role as
    // the "Name" — gives the embedder signal about who said what without
    // leaking persona names (which may be long / contain macros).
    final parts = <String>[];
    for (final m in slice) {
      parts.add('${m.role}: ${m.content}');
    }
    return parts.join('\n\n');
  }
}

class _MessageChunk {
  final int index;
  final String text;
  final List<String> messageIds;
  const _MessageChunk({
    required this.index,
    required this.text,
    required this.messageIds,
  });
}
