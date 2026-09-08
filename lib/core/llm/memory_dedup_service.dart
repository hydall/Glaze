import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../db/repositories/embedding_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../models/api_config.dart';
import '../models/memory_book.dart';
import '../models/pipeline_settings.dart';
import 'aux_llm_client.dart';
import 'json_repair.dart';
import 'transport/llm_protocol.dart';
import 'vector_math.dart';

/// Result of a single dedup decision for a pair of near-duplicate entries.
typedef DedupPairDecision = ({String entryAId, String entryBId, String action, String? mergedContent, String? mergedTitle, List<String>? mergedKeys});

/// Overall result of a dedup run.
class MemoryDedupResult {
  final String status;
  final int candidatesChecked;
  final int pairsSentToLlm;
  final int merged;
  final int dropped;
  final int kept;
  final int totalElapsedMs;

  const MemoryDedupResult({
    this.status = 'ok',
    this.candidatesChecked = 0,
    this.pairsSentToLlm = 0,
    this.merged = 0,
    this.dropped = 0,
    this.kept = 0,
    this.totalElapsedMs = 0,
  });
}

/// Service that deduplicates memory entries using cosine similarity pre-filter
/// and a batch LLM call to decide merge/drop/keep for each candidate pair.
///
/// Pipeline:
/// 1. Load active entries from MemoryBook (optionally filtered by swipe selection).
/// 2. Load embeddings for those entries from the EmbeddingRepo.
/// 3. Compute pairwise cosine similarity; collect pairs with score > [threshold].
/// 4. Send all candidate pairs to the LLM in one batch call; LLM decides per pair:
///    - "merge": combine content from both entries into one
///    - "drop": delete the redundant entry
///    - "keep": both entries are sufficiently distinct, no action
/// 5. Apply the decisions atomically via MemoryBookRepo.
class MemoryDedupService {
  final AuxLlmClient _llm;
  final EmbeddingRepo _embeddingRepo;
  final MemoryBookRepo _bookRepo;
  final Future<List<ApiConfig>> Function() _loadApiConfigs;
  final ApiConfig? Function() _activeApiConfig;

  MemoryDedupService({
    required this._llm,
    required this._embeddingRepo,
    required this._bookRepo,
    required this._loadApiConfigs,
    required this._activeApiConfig,
  });

  /// Run the dedup pass on the memory book for [sessionId].
  ///
  /// [entryIds] — if non-null, only consider entries whose IDs are in this set
  /// (used for swipe-selection filtering: only entries that appeared in
  /// triggeredMemories of the currently selected swipes).
  ///
  /// [threshold] — cosine similarity threshold for candidate pairs (default 0.85).
  /// [cancelToken] — optional cancellation token.
  /// [isStillCurrent] — optional staleness guard; if it returns false, aborts.
  Future<MemoryDedupResult> runDedup({
    required String sessionId,
    required PipelineSettings settings,
    Set<String>? entryIds,
    double threshold = 0.85,
    CancelToken? cancelToken,
    bool Function()? isStillCurrent,
  }) async {
    final startedMs = DateTime.now().millisecondsSinceEpoch;

    try {
      // 1. Load the MemoryBook and filter entries.
      final book = await _bookRepo.getBySessionId(sessionId);
      if (book == null) {
        return const MemoryDedupResult(status: 'no_book');
      }

      var entries = book.entries
          .where((e) => e.status == 'active' && e.content.trim().isNotEmpty)
          .toList();

      // Filter by entryIds if provided (swipe selection scope).
      if (entryIds != null && entryIds.isNotEmpty) {
        entries = entries.where((e) => entryIds.contains(e.id)).toList();
      }

      if (entries.length < 2) {
        return MemoryDedupResult(
          status: 'ok',
          candidatesChecked: entries.length,
          totalElapsedMs: DateTime.now().millisecondsSinceEpoch - startedMs,
        );
      }

      // 2. Load embeddings for all candidate entries.
      final embeddings = <String, List<double>>{};
      for (final entry in entries) {
        final row = await _embeddingRepo.getByEntryId(entry.id);
        if (row != null && _embeddingRepo.hasUsableVectors(row)) {
          final vectors = _embeddingRepo.decodeVectors(row);
          if (vectors != null && vectors.isNotEmpty) {
            // Use the first chunk vector as the entry representation.
            embeddings[entry.id] = vectors.first;
          }
        }
      }

      // 3. Compute pairwise cosine similarity; collect candidate pairs.
      final candidatePairs = <({MemoryEntry a, MemoryEntry b, double score})>[];
      for (int i = 0; i < entries.length; i++) {
        final vecA = embeddings[entries[i].id];
        if (vecA == null) continue;
        for (int j = i + 1; j < entries.length; j++) {
          final vecB = embeddings[entries[j].id];
          if (vecB == null) continue;
          final score = cosineSimilarity(vecA, vecB);
          if (score >= threshold) {
            candidatePairs.add((a: entries[i], b: entries[j], score: score));
          }
        }
      }

      if (candidatePairs.isEmpty) {
        return MemoryDedupResult(
          status: 'ok',
          candidatesChecked: entries.length,
          pairsSentToLlm: 0,
          totalElapsedMs: DateTime.now().millisecondsSinceEpoch - startedMs,
        );
      }

      // 4. Build the batch LLM prompt with all candidate pairs.
      final config = await _resolveMemoryBookConfig(
        settings,
        errorLabel: 'memory dedup',
      );
      if (cancelToken?.isCancelled == true || isStillCurrent?.call() == false) {
        return const MemoryDedupResult(status: 'aborted');
      }

      final prompt = _buildBatchPrompt(candidatePairs);
      final maxTokens = (settings.memoryBookApi.generationMaxTokens != null &&
              settings.memoryBookApi.generationMaxTokens! > 0)
          ? settings.memoryBookApi.generationMaxTokens!
          : 25000;
      final outcome = await _llm.callOnceWithLog(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: 0.1,
        timeoutMs: settings.memoryPipeline.auxTimeoutMs,
        cancelToken: cancelToken,
      );

      if (cancelToken?.isCancelled == true || isStillCurrent?.call() == false) {
        return const MemoryDedupResult(status: 'aborted');
      }

      if (!outcome.isOk || outcome.text == null) {
        return MemoryDedupResult(
          status: 'llm_error',
          candidatesChecked: entries.length,
          pairsSentToLlm: candidatePairs.length,
          totalElapsedMs: DateTime.now().millisecondsSinceEpoch - startedMs,
        );
      }

      // 5. Parse the LLM response.
      final decisions = _parseBatchResponse(outcome.text!, candidatePairs);
      if (decisions.isEmpty) {
        return MemoryDedupResult(
          status: 'ok',
          candidatesChecked: entries.length,
          pairsSentToLlm: candidatePairs.length,
          totalElapsedMs: DateTime.now().millisecondsSinceEpoch - startedMs,
        );
      }

      // 6. Apply decisions atomically.
      int merged = 0, dropped = 0, kept = 0;
      final deletedIds = <String>{};

      for (final decision in decisions) {
        // Skip if one of the entries was already deleted by a prior decision.
        if (deletedIds.contains(decision.entryAId) ||
            deletedIds.contains(decision.entryBId)) {
          continue;
        }

        switch (decision.action) {
          case 'merge':
            if (decision.mergedContent != null) {
              final targetId = decision.entryAId;
              final sourceId = decision.entryBId;
              final existing = book.entries.firstWhere(
                (e) => e.id == targetId,
                orElse: () => book.entries.first,
              );
              final updated = existing.copyWith(
                content: decision.mergedContent!,
                title: decision.mergedTitle ?? existing.title,
                keys: decision.mergedKeys ?? existing.keys,
              );
              await _bookRepo.updateEntry(
                sessionId: sessionId,
                entryId: targetId,
                updated: updated,
              );
              await _bookRepo.deleteEntry(
                sessionId: sessionId,
                entryId: sourceId,
              );
              await _embeddingRepo.deleteByEntryId(sourceId);
              deletedIds.add(sourceId);
              merged++;
            } else {
              kept++;
            }
            break;
          case 'drop':
            // Drop entry B (the redundant one).
            await _bookRepo.deleteEntry(
              sessionId: sessionId,
              entryId: decision.entryBId,
            );
            await _embeddingRepo.deleteByEntryId(decision.entryBId);
            deletedIds.add(decision.entryBId);
            dropped++;
            break;
          case 'keep':
          default:
            kept++;
            break;
        }
      }

      return MemoryDedupResult(
        status: 'ok',
        candidatesChecked: entries.length,
        pairsSentToLlm: candidatePairs.length,
        merged: merged,
        dropped: dropped,
        kept: kept,
        totalElapsedMs: DateTime.now().millisecondsSinceEpoch - startedMs,
      );
    } on TimeoutException {
      return MemoryDedupResult(
        status: 'timeout',
        totalElapsedMs: DateTime.now().millisecondsSinceEpoch - startedMs,
      );
    } catch (e) {
      debugPrint('[MemoryDedup] error: $e');
      return MemoryDedupResult(
        status: 'error',
        totalElapsedMs: DateTime.now().millisecondsSinceEpoch - startedMs,
      );
    }
  }

  /// Resolves the MemoryBook API config from [settings.memoryBookApi].
  /// Falls back to the active chat API config when source is 'current'.
  Future<AuxApiConfig> _resolveMemoryBookConfig(
    PipelineSettings settings, {
    String errorLabel = 'memory',
  }) async {
    final mb = settings.memoryBookApi;
    if (mb.generationSource == 'custom') {
      if (mb.generationEndpoint.isEmpty || mb.generationModel.isEmpty) {
        throw Exception('MemoryBook custom config incomplete for $errorLabel');
      }
      return AuxApiConfig(
        endpoint: mb.generationEndpoint,
        apiKey: mb.generationApiKey,
        model: mb.generationModel,
        protocol: LlmProtocol.openai,
      );
    }

    // Ensure API list is loaded before reading the active config.
    await _loadApiConfigs();
    final chatConfig = _activeApiConfig();
    if (chatConfig == null) {
      throw Exception('No chat API config available for $errorLabel');
    }
    final model = mb.generationModel.isNotEmpty
        ? mb.generationModel
        : chatConfig.model;
    return AuxApiConfig(
      endpoint: chatConfig.endpoint,
      apiKey: chatConfig.apiKey,
      model: model,
      protocol: chatConfig.protocol,
    );
  }

  /// Build the batch LLM prompt for all candidate pairs.
  String _buildBatchPrompt(
    List<({MemoryEntry a, MemoryEntry b, double score})> pairs,
  ) {
    final pairsBlock = StringBuffer();
    for (int i = 0; i < pairs.length; i++) {
      final pair = pairs[i];
      pairsBlock.writeln('--- PAIR $i (cosine: ${pair.score.toStringAsFixed(3)}) ---');
      pairsBlock.writeln('Entry A [id: ${pair.a.id}]');
      pairsBlock.writeln('  Title: ${pair.a.title}');
      pairsBlock.writeln('  Content: ${pair.a.content}');
      pairsBlock.writeln('  Keys: ${pair.a.keys.join(', ')}');
      pairsBlock.writeln('Entry B [id: ${pair.b.id}]');
      pairsBlock.writeln('  Title: ${pair.b.title}');
      pairsBlock.writeln('  Content: ${pair.b.content}');
      pairsBlock.writeln('  Keys: ${pair.b.keys.join(', ')}');
      pairsBlock.writeln();
    }

    return '''You are a memory deduplication assistant. You are given pairs of memory entries that have high semantic similarity (cosine > 0.85). For each pair, decide whether to merge, drop, or keep both.

$pairsBlock

For each pair, respond with a JSON array (no markdown, no explanation):
[
  {
    "pair": 0,
    "action": "merge",
    "mergedTitle": "Combined title",
    "mergedContent": "Combined content from both entries, preserving all unique facts",
    "mergedKeys": ["key1", "key2"]
  },
  {
    "pair": 1,
    "action": "drop"
  },
  {
    "pair": 2,
    "action": "keep"
  }
]

Rules:
- "merge": The two entries are about the same topic/person/event with overlapping information. Combine them into a single entry. Keep entry A (lower index in the pair), delete entry B. Provide mergedTitle, mergedContent, and mergedKeys that combine the unique information from both.
- "drop": Entry B is a strict duplicate or subset of entry A. Delete entry B, keep entry A as-is.
- "keep": The entries are similar but contain distinct, non-overlapping information. Keep both.
- mergedContent should be concise (1-5 sentences), combining unique facts from both entries without redundancy.
- mergedKeys should combine keys from both entries without duplicates.
- Respond for ALL pairs, in order.''';
  }

  /// Parse the batch LLM response into a list of decisions.
  List<DedupPairDecision> _parseBatchResponse(
    String text,
    List<({MemoryEntry a, MemoryEntry b, double score})> pairs,
  ) {
    try {
      final raw = extractJsonArray(text);
      if (raw == null) return [];
      final decoded = jsonDecode(repairJson(raw));
      if (decoded is! List) return [];

      final decisions = <DedupPairDecision>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        final pairIdx = item['pair'];
        if (pairIdx is! int || pairIdx < 0 || pairIdx >= pairs.length) continue;
        final action = item['action']?.toString() ?? 'keep';
        if (action != 'merge' && action != 'drop' && action != 'keep') continue;

        final pair = pairs[pairIdx];
        decisions.add((
          entryAId: pair.a.id,
          entryBId: pair.b.id,
          action: action,
          mergedContent: item['mergedContent']?.toString(),
          mergedTitle: item['mergedTitle']?.toString(),
          mergedKeys: (item['mergedKeys'] as List?)
              ?.map((e) => e.toString())
              .toList(),
        ));
      }
      return decisions;
    } catch (e) {
      debugPrint('[MemoryDedup] failed to parse LLM response: $e');
      return [];
    }
  }
}
