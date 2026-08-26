import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/app_db.dart';
import '../../db/repositories/card_evolution_repo.dart';
import 'durable_writer_call_runner.dart';

typedef DiscardOrRetainWriter =
    Future<void> Function(
      CardEvolutionClaim claim,
      String owner,
      List<CardEvolutionWriterCallRow> chain,
      String code,
      String? detail,
    );

typedef SnapshotTooLarge =
    CardEvolutionFinalizeOutcome Function(
      int actual, {
      String stage,
      int limit,
    });

/// Consolidates oversized immutable history into the durable writer context.
final class WriterContextConsolidator {
  const WriterContextConsolidator({
    required this.writerCallRunner,
    required this.discardOrRetainWriter,
    required this.snapshotTooLarge,
  });

  static const snapshotCharacterLimit = 600000;
  static const contextCharacterLimit = 400000;
  static const _historyConsolidationInstruction =
      'Consolidate this next immutable Card Rewriter evidence segment into a '
      'compact cumulative factual handoff. Preserve all durable character '
      'changes, relationship developments, exact identities, supporting message '
      'IDs, and contradictions from both the prior handoff and this segment. Do '
      'not propose or apply card patches. Do not invent facts.';

  final DurableWriterCallRunner writerCallRunner;
  final DiscardOrRetainWriter discardOrRetainWriter;
  final SnapshotTooLarge snapshotTooLarge;

  Future<PreparedWriterContext> prepare({
    required CardEvolutionClaim claim,
    required String owner,
    required LazyWriterModel model,
    required String selectedInputJson,
    required CancelToken cancelToken,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int nextOrdinal,
    required String? parentCallId,
    required String? manualCallId,
    required String? manualResponse,
  }) async {
    if (selectedInputJson.length <= contextCharacterLimit) {
      return PreparedWriterContext.context(
        selectedInputJson,
        chainIndex: chainIndex,
        nextOrdinal: nextOrdinal,
        parentCallId: parentCallId,
      );
    }
    Map<String, dynamic> decoded;
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(selectedInputJson) as Map);
    } catch (_) {
      await discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Stored writer input cannot be decoded for consolidation',
      );
      return PreparedWriterContext.failure(
        snapshotTooLarge(
          selectedInputJson.length,
          limit: contextCharacterLimit,
        ),
      );
    }
    final history = decoded['chatHistory'];
    if (history is! List) {
      await discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Stored writer input has no valid chat history',
      );
      return PreparedWriterContext.failure(
        snapshotTooLarge(
          selectedInputJson.length,
          limit: contextCharacterLimit,
        ),
      );
    }
    final common = Map<String, dynamic>.from(decoded)
      ..remove('writerCollectorMessageIds')
      ..remove('chatHistory');
    if (jsonEncode(common).length > contextCharacterLimit) {
      await discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Shared writer context exceeds the safe request limit',
      );
      return PreparedWriterContext.failure(
        snapshotTooLarge(
          jsonEncode(common).length,
          stage: 'shared context',
          limit: contextCharacterLimit,
        ),
      );
    }
    String? handoff;
    var offset = 0;
    var stageOrdinal = 1;
    while (offset < history.length) {
      final chunk = <Object?>[];
      String? prompt;
      while (offset + chunk.length < history.length) {
        final candidate = [...chunk, history[offset + chunk.length]];
        final candidatePrompt = _historyConsolidationPrompt(
          common: common,
          priorHandoff: handoff,
          history: candidate,
        );
        if (candidatePrompt.length > snapshotCharacterLimit) break;
        chunk.add(history[offset + chunk.length]);
        prompt = candidatePrompt;
      }
      if (chunk.isEmpty || prompt == null) {
        await discardOrRetainWriter(
          claim,
          owner,
          chain,
          'snapshotTooLarge',
          'A history consolidation chunk exceeds the safe request limit',
        );
        return PreparedWriterContext.failure(
          snapshotTooLarge(
            _historyConsolidationPrompt(
              common: common,
              priorHandoff: handoff,
              history: [history[offset]],
            ).length,
            stage: 'history message ${offset + 1}',
          ),
        );
      }
      final call = await writerCallRunner.runTextCall(
        claim: claim,
        owner: owner,
        model: model,
        token: cancelToken,
        chain: chain,
        chainIndex: chainIndex,
        ordinal: nextOrdinal,
        stage: 'history_consolidation',
        stageOrdinal: stageOrdinal,
        captureStage: 'card.history_consolidation',
        prompt: prompt,
        parentCallId: parentCallId,
        manualCallId: manualCallId,
        manualResponse: manualResponse,
      );
      if (call.failure != null) {
        return PreparedWriterContext.failure(call.failure!);
      }
      handoff = call.call!.responseText;
      parentCallId = call.call!.lastCallId;
      offset += chunk.length;
      chainIndex++;
      nextOrdinal++;
      stageOrdinal++;
    }
    final context = jsonEncode({
      ...common,
      'chatHistory': const <Object?>[],
      'completeHistoryConsolidation': handoff,
    });
    if (context.length > contextCharacterLimit) {
      await discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Final consolidated writer context exceeds the safe request limit',
      );
      return PreparedWriterContext.failure(
        snapshotTooLarge(
          context.length,
          stage: 'final writer context',
          limit: contextCharacterLimit,
        ),
      );
    }
    return PreparedWriterContext.context(
      context,
      chainIndex: chainIndex,
      nextOrdinal: nextOrdinal,
      parentCallId: parentCallId,
    );
  }

  static String _historyConsolidationPrompt({
    required Map<String, dynamic> common,
    required String? priorHandoff,
    required List<Object?> history,
  }) =>
      '$_historyConsolidationInstruction\n\n'
      '# Prior cumulative handoff\n${priorHandoff ?? '(none)'}\n\n'
      '# Shared card, canon, and lorebook context\n${jsonEncode(common)}\n\n'
      '# Next immutable chat-history segment\n${jsonEncode(history)}';
}

final class PreparedWriterContext {
  const PreparedWriterContext.context(
    this.context, {
    this.chainIndex = 0,
    this.nextOrdinal = 1,
    this.parentCallId,
  }) : failure = null;

  const PreparedWriterContext.failure(this.failure)
    : context = null,
      chainIndex = 0,
      nextOrdinal = 1,
      parentCallId = null;

  final String? context;
  final CardEvolutionFinalizeOutcome? failure;
  final int chainIndex;
  final int nextOrdinal;
  final String? parentCallId;
}
