import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/macro_engine.dart';
import '../../../core/llm/memory_book_api_config_resolver.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/models/summary_block.dart';
import '../../../core/services/summary_preamble.dart';
import '../../../core/services/summary_prompt_presets.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/summary_providers.dart';
import '../../settings/api_list_provider.dart';
import '../state/cached_token_breakdown.dart';

final summaryGenerationServiceProvider = Provider<SummaryGenerationService>(
  (ref) => SummaryGenerationService(ref),
);

/// What one compaction run did.
class SummaryCompactionResult {
  final int created;
  final int merged;

  const SummaryCompactionResult({this.created = 0, this.merged = 0});

  bool get changed => created > 0 || merged > 0;
}

/// Where a compaction run stands, reported before each request it sends.
class SummaryCompactionProgress {
  /// Blocks written so far in this run.
  final int created;
  final int merged;

  /// Adjacent blocks are being merged a level up rather than messages retold.
  final bool merging;

  /// Ids of the messages being retold now; empty while merging, and before
  /// the first request has been planned.
  final List<String> sourceIds;

  /// Summarizable messages outside the fresh tail still uncovered once the
  /// step under way lands.
  final int remainingMessages;

  const SummaryCompactionProgress({
    this.created = 0,
    this.merged = 0,
    this.merging = false,
    this.sourceIds = const [],
    this.remainingMessages = 0,
  });
}

/// Keeps the chat's summary chain in shape and runs every change to it.
///
/// Compaction is driven by how full the prompt is, not by a message count —
/// messages range from a line to a page, so a count says little about room.
/// Once the prompt passes the trigger share of what it may use, the oldest
/// messages are retold as a level-1 block, which then stands in for them,
/// until the prompt is under the line it compacts to (the trigger, or lower
/// — `SummaryCompactionSettings.compactToPercent`): the fresh tail sent as
/// written is what fits under that line next to the rest of the prompt (see
/// [autoTailBudget]). The source is always the oldest messages no block
/// stands in for yet, so what the history trim dropped from the prompt is
/// retold first once a run is due. When the live blocks themselves outgrow
/// their share, adjacent blocks of one level are merged a level up.
///
/// The connection is the Memory slot's (`PipelineSettings.memoryBookApi`), the
/// same one memory drafts run on, falling back to the active chat connection.
///
/// Shared by the Memory sheet, the auto-summary stage and
/// `ChatActionsService`, so all of them produce identical prompts.
class SummaryGenerationService {
  final Ref _ref;

  SummaryGenerationService(this._ref);

  /// Sessions with a compaction or merge in flight. One at a time per session:
  /// two runs would pick the same messages.
  static final Set<String> _running = {};

  static bool isRunning(String sessionId) => _running.contains(sessionId);

  /// Upper bound on steps of an automatic run: it goes between two turns of
  /// the chat, so it stops short rather than hold the next one up.
  static const _maxSteps = 12;

  /// Steps in a row that wrote nothing — the chat was edited under each of
  /// them — before a run gives up. Keeps a run from spinning on a chat that
  /// changes faster than it is retold.
  static const _maxIdleSteps = 3;

  /// Compacts [session] until the prompt is back under the trigger. [force]
  /// ignores the trigger and the minimum run size, keeps only the manual tail
  /// (`manualTailBudget`) as raw history rather than the rest of the window,
  /// and keeps going, one block at a time, until everything older is
  /// summarized — the whole backlog of a long chat, however many blocks it
  /// takes.
  ///
  /// [onProgress] hears where the run stands before each request. A
  /// cancelled [cancelToken] ends the run after the step under way: the
  /// request already sent is not aborted, its block is written, and nothing
  /// follows. Every block written stays.
  ///
  /// Throws [SummaryChainException] `busy` when a run is already going, and
  /// whatever the transport throws.
  Future<SummaryCompactionResult> compact({
    required String charId,
    required ChatSession session,
    bool force = false,
    CancelToken? cancelToken,
    void Function(SummaryCompactionProgress progress)? onProgress,
  }) {
    return _exclusive(session.id, () async {
      final settings = await _ref.read(
        summaryCompactionSettingsProvider.future,
      );
      final slot = _ref.read(pipelineSettingsProvider).memoryBookApi;
      final apiConfig = await _requireConfig(slot);
      final service = _ref.read(summaryServiceProvider);
      final template = await _retellTemplate(session.id);
      final mergeTemplate = await _mergeTemplate();
      final shortenTemplate = await _shortenTemplate();
      final inputCap = _summarizerInputCap(apiConfig);

      var messages = await _messages(session.id, session.messages);
      final budget = _promptBudget(charId);
      final compactTo = settings.compactToTokens(budget.total);
      var created = 0;
      var merged = 0;
      var idle = 0;

      for (var step = 0; force || step < _maxSteps; step++) {
        if (cancelToken?.isCancelled == true) break;
        messages = await _messages(session.id, session.messages);
        final blocks = await _cleanBlocks(session.id, messages);
        final view = SummaryChain.promptView(blocks, messages);
        final summaryTokens = SummaryChain.liveTokens(blocks, messages);
        final historyTokens = messages
            .where(SummaryChain.isSummarizable)
            .where((m) => !view.coveredMessageIds.contains(m.id))
            .fold(0, (sum, m) => sum + estimateTokens(m.content));
        final used = budget.fixedTokens + summaryTokens + historyTokens;

        if (summaryTokens > budget.total * settings.mergePercent ~/ 100) {
          final parts = SummaryChain.mergeCandidate(
            blocks,
            messages,
            maxInputTokens: inputCap,
          );
          if (parts.isNotEmpty) {
            onProgress?.call(
              SummaryCompactionProgress(
                created: created,
                merged: merged,
                merging: true,
              ),
            );
            await _merge(
              sessionId: session.id,
              parts: parts,
              messages: messages,
              apiConfig: apiConfig,
              settings: settings,
              template: mergeTemplate,
              shortenTemplate: shortenTemplate,
              temperature: slot.generationTemperature,
              // Not [cancelToken]: a stop lets the step under way land.
            );
            merged++;
            continue;
          }
        }

        final triggerTokens = budget.total * settings.triggerPercent ~/ 100;
        if (!force && used < triggerTokens) break;
        final tail = autoTailBudget(
          total: budget.total,
          compactToTokens: compactTo,
          fixedTokens: budget.fixedTokens,
          summaryTokens: summaryTokens,
        );
        final plan = SummaryChain.planSource(
          blocks: blocks,
          messages: messages,
          tailBudgetTokens: force
              ? settings.manualTailBudget(_contextSize(budget))
              : tail,
          maxSourceTokens: inputCap,
        );
        if (plan.source.isEmpty) break;
        final overflow = used > budget.total;
        final minSource = math.max(1000, settings.blockTargetTokens * 2);
        if (!force && !overflow && plan.sourceTokens < minSource) break;
        final target = _targetFor(plan.sourceTokens, settings);
        // A block barely smaller than its messages frees nothing.
        if (target * 11 ~/ 10 >= plan.sourceTokens) break;

        final earlier = SummaryChain.liveBefore(
          blocks,
          messages,
          plan.source.first.id,
        );
        onProgress?.call(
          SummaryCompactionProgress(
            created: created,
            merged: merged,
            sourceIds: [for (final m in plan.source) m.id],
            remainingMessages: plan.remainingMessages - plan.source.length,
          ),
        );

        final text = await service.summarizeMessages(
          sessionId: session.id,
          source: plan.source,
          apiConfig: apiConfig,
          targetTokens: target,
          earlierSummary: SummaryChain.render(earlier),
          customPrompt: template,
          shortenTemplate: shortenTemplate,
          macroContext: _macroContext(charId: charId, session: session),
          // Not [cancelToken]: a stop lets the step under way land.
          temperature: slot.generationTemperature,
        );
        final tokens = _acceptedTokens(text, plan.sourceTokens);
        final ids = [for (final m in plan.source) m.id];
        final block = SummaryBlock(
          id: _newId(),
          level: 1,
          content: text,
          messageIds: ids,
          sourceHash: SummaryChain.fingerprint(
            ids,
            SummaryChain.index(messages),
          ),
          tokens: tokens,
          sourceTokens: plan.sourceTokens,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        if (!await _commit(session.id, session.messages, (blocks, current) {
          // Edited while the summarizer was writing: the block describes
          // text that no longer exists. The next step picks the run again.
          if (SummaryChain.isStale(block, SummaryChain.index(current))) {
            return null;
          }
          return SummaryChain.commitSource(blocks, current, block);
        })) {
          if (++idle >= _maxIdleSteps) break;
          continue;
        }
        idle = 0;
        created++;
      }
      return SummaryCompactionResult(created: created, merged: merged);
    });
  }

  /// Merges the reader's selection — adjacent live blocks of one level.
  Future<void> mergeSelected({
    required ChatSession session,
    required Set<String> blockIds,
    CancelToken? cancelToken,
  }) {
    return _exclusive(session.id, () async {
      final settings = await _ref.read(
        summaryCompactionSettingsProvider.future,
      );
      final slot = _ref.read(pipelineSettingsProvider).memoryBookApi;
      final apiConfig = await _requireConfig(slot);
      final messages = await _messages(session.id, session.messages);
      final blocks = await _cleanBlocks(session.id, messages);
      final parts = SummaryChain.manualMergeSelection(
        blocks,
        messages,
        blockIds,
      );
      await _merge(
        sessionId: session.id,
        parts: parts,
        messages: messages,
        apiConfig: apiConfig,
        settings: settings,
        template: await _mergeTemplate(),
        shortenTemplate: await _shortenTemplate(),
        temperature: slot.generationTemperature,
        cancelToken: cancelToken,
      );
    });
  }

  /// Writes an active block again over the same sources, on the prompts
  /// chosen now, and leaves the result on it as a [SummaryDraft] for the
  /// reader to approve ([approveDraft]) — the block keeps its text until then.
  /// A level-1 block retells its messages as they read today, so approving
  /// brings a stale one back; a merge is merged again from its parts. A merge
  /// whose messages changed is refused (`stale_merge`): its parts are as out
  /// of date as it is, and deleting it gives them back. A stopped run
  /// ([cancelToken]) writes nothing.
  Future<void> regenerateBlock({
    required String charId,
    required ChatSession session,
    required String blockId,
    CancelToken? cancelToken,
  }) {
    return _exclusive(session.id, () async {
      final settings = await _ref.read(
        summaryCompactionSettingsProvider.future,
      );
      final slot = _ref.read(pipelineSettingsProvider).memoryBookApi;
      final apiConfig = await _requireConfig(slot);
      final service = _ref.read(summaryServiceProvider);
      final messages = await _messages(session.id, session.messages);
      final byId = SummaryChain.index(messages);
      final blocks = await service.getBlocks(session.id);
      final block = blocks
          .where((b) => b.id == blockId && !b.archived && !b.isNote)
          .firstOrNull;
      if (block == null) throw const SummaryChainException('not_live');

      final String text;
      final List<String> ids;
      final int sourceTokens;
      if (block.childIds.isEmpty) {
        final source = [
          for (final id in block.messageIds)
            if (byId[id] case final message?
                when SummaryChain.isSummarizable(message))
              message,
        ];
        if (source.isEmpty) throw const SummaryChainException('sources_gone');
        ids = [for (final m in source) m.id];
        sourceTokens = source.fold(
          0,
          (sum, m) => sum + estimateTokens(m.content),
        );
        final earlier = SummaryChain.liveBefore(
          blocks,
          messages,
          ids.first,
        ).where((b) => b.id != block.id);
        text = await service.summarizeMessages(
          sessionId: session.id,
          source: source,
          apiConfig: apiConfig,
          targetTokens: _targetFor(sourceTokens, settings),
          earlierSummary: SummaryChain.render(earlier),
          customPrompt: await _retellTemplate(session.id),
          shortenTemplate: await _shortenTemplate(),
          macroContext: _macroContext(charId: charId, session: session),
          cancelToken: cancelToken,
          temperature: slot.generationTemperature,
        );
      } else {
        if (SummaryChain.isStale(block, byId)) {
          throw const SummaryChainException('stale_merge');
        }
        final parts = [
          for (final id in block.childIds)
            ?blocks.where((b) => b.id == id).firstOrNull,
        ];
        if (parts.length != block.childIds.length) {
          throw const SummaryChainException('not_live');
        }
        ids = block.messageIds;
        sourceTokens = parts.fold(0, (sum, b) => sum + b.tokens);
        text = await service.mergeBlocks(
          sessionId: session.id,
          parts: parts,
          apiConfig: apiConfig,
          targetTokens: _targetFor(sourceTokens, settings),
          template: await _mergeTemplate(),
          shortenTemplate: await _shortenTemplate(),
          cancelToken: cancelToken,
          temperature: slot.generationTemperature,
        );
      }

      final tokens = _acceptedTokens(text, sourceTokens);
      final draft = SummaryDraft(
        content: text,
        messageIds: ids,
        sourceHash: SummaryChain.fingerprint(ids, byId),
        tokens: tokens,
        sourceTokens: sourceTokens,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      bool stopped() => cancelToken?.isCancelled ?? false;
      final committed = await _commit(session.id, messages, (current, now) {
        // Stopped, or edited while the summarizer was writing: the draft
        // describes messages that no longer read that way.
        if (stopped() ||
            SummaryChain.isDraftStale(draft, SummaryChain.index(now))) {
          return null;
        }
        return SummaryChain.putDraft(current, block.id, draft);
      });
      if (!committed && !stopped()) {
        throw const SummaryChainException('changed');
      }
    });
  }

  /// Puts the draft [regenerateBlock] left on [blockId] in place of the
  /// block's text. Throws `changed` when its messages changed after it was
  /// written.
  Future<void> approveDraft({
    required ChatSession session,
    required String blockId,
  }) async {
    await _commit(
      session.id,
      session.messages,
      (blocks, messages) =>
          SummaryChain.approveDraft(blocks, messages, blockId),
    );
  }

  Future<void> editDraft({
    required ChatSession session,
    required String blockId,
    required String content,
  }) async {
    if (content.trim().isEmpty) return;
    await _commit(
      session.id,
      session.messages,
      (blocks, _) => SummaryChain.editDraft(blocks, blockId, content),
    );
  }

  /// Drops the draft of [blockId]; the block keeps the text it has.
  Future<void> discardDraft({
    required ChatSession session,
    required String blockId,
  }) async {
    await _commit(
      session.id,
      session.messages,
      (blocks, _) => SummaryChain.putDraft(blocks, blockId, null),
    );
  }

  Future<void> editBlock({
    required ChatSession session,
    required String blockId,
    required String content,
  }) async {
    if (content.trim().isEmpty) {
      return deleteBlock(session: session, blockId: blockId);
    }
    await _commit(
      session.id,
      session.messages,
      (blocks, _) => SummaryChain.edit(blocks, blockId, content),
    );
  }

  /// Deletes an active block. A merge gives its parts back; a level-1 block
  /// lets its messages return to the prompt.
  Future<void> deleteBlock({
    required ChatSession session,
    required String blockId,
  }) => _commit(
    session.id,
    session.messages,
    (blocks, _) => SummaryChain.delete(blocks, blockId),
  );

  /// Adds a note the reader writes: sent with the summary, standing in for
  /// no messages.
  Future<void> addNote({
    required ChatSession session,
    required String content,
  }) async {
    final text = content.trim();
    if (text.isEmpty) return;
    await _commit(
      session.id,
      session.messages,
      (blocks, _) => [
        ...blocks,
        SummaryBlock(
          id: _newId(),
          level: 0,
          content: text,
          tokens: estimateTokens(text),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
    );
  }

  /// Empties the chain, archive included. Messages are untouched and return
  /// to the prompt.
  Future<void> clear({required ChatSession session}) =>
      _commit(session.id, session.messages, (_, _) => const []);

  Future<void> _merge({
    required String sessionId,
    required List<SummaryBlock> parts,
    required List<ChatMessage> messages,
    required ApiConfig apiConfig,
    required SummaryCompactionSettings settings,
    String? template,
    String? shortenTemplate,
    double? temperature,
    CancelToken? cancelToken,
  }) async {
    final sourceTokens = parts.fold(0, (sum, b) => sum + b.tokens);
    final target = _targetFor(sourceTokens, settings);
    final text = await _ref
        .read(summaryServiceProvider)
        .mergeBlocks(
          sessionId: sessionId,
          parts: parts,
          apiConfig: apiConfig,
          targetTokens: target,
          template: template,
          shortenTemplate: shortenTemplate,
          cancelToken: cancelToken,
          temperature: temperature,
        );
    final tokens = _acceptedTokens(text, sourceTokens);
    final ids = [for (final part in parts) ...part.messageIds];
    final merged = SummaryBlock(
      id: _newId(),
      level: parts.first.level + 1,
      content: text,
      messageIds: ids,
      sourceHash: SummaryChain.fingerprint(ids, SummaryChain.index(messages)),
      childIds: [for (final part in parts) part.id],
      tokens: tokens,
      sourceTokens: sourceTokens,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final committed = await _commit(sessionId, messages, (blocks, current) {
      if (SummaryChain.isStale(merged, SummaryChain.index(current))) {
        return null;
      }
      return SummaryChain.commitMerge(blocks, merged);
    });
    if (!committed) throw const SummaryChainException('changed');
  }

  /// The summarizer's answer as the size of the block it makes. Text no
  /// shorter than its source frees nothing (`not_shorter`) and is not written.
  static int _acceptedTokens(String text, int sourceTokens) {
    final tokens = estimateTokens(text);
    if (tokens >= sourceTokens) {
      throw const SummaryChainException('not_shorter');
    }
    return tokens;
  }

  /// The chat's own prompt text when it still has one, else the chosen
  /// retelling preset — with the reader's preamble in front when it is on.
  Future<String> _retellTemplate(String sessionId) async {
    final own = await _ref
        .read(summaryServiceProvider)
        .getSummaryPrompt(sessionId);
    if (own != null) return _withPreamble(own);
    final selection = await _ref.read(summaryPromptSelectionProvider.future);
    final custom = await _ref.read(summaryCustomPromptsProvider.future);
    return _withPreamble(
      SummaryPromptPresets.resolve(selection.retellKey, custom).prompt,
    );
  }

  Future<String> _mergeTemplate() async {
    final selection = await _ref.read(summaryPromptSelectionProvider.future);
    final custom = await _ref.read(summaryCustomMergePromptsProvider.future);
    return _withPreamble(
      SummaryMergePromptPresets.resolve(selection.mergeKey, custom).prompt,
    );
  }

  Future<String> _shortenTemplate() async {
    final selection = await _ref.read(summaryPromptSelectionProvider.future);
    final custom = await _ref.read(summaryCustomShortenPromptsProvider.future);
    return _withPreamble(
      SummaryShortenPromptPresets.resolve(selection.shortenKey, custom).prompt,
    );
  }

  /// [template] behind the preamble ([SummaryPreamble]) when the reader has
  /// it on: first in every summary prompt, so it is read before the prompt it
  /// is meant to steer. Off, [template] goes as it is.
  Future<String> _withPreamble(String template) async {
    final preamble = await _ref.read(summaryPreambleProvider.future);
    return preamble.apply(template);
  }

  /// Reads the messages fresh, then applies [change] to the blocks as stored
  /// and saves them in one transaction. A null from [change] skips the write.
  /// Returns whether anything was written.
  Future<bool> _commit(
    String sessionId,
    List<ChatMessage> fallbackMessages,
    List<SummaryBlock>? Function(
      List<SummaryBlock> blocks,
      List<ChatMessage> messages,
    )
    change,
  ) async {
    final messages = await _messages(sessionId, fallbackMessages);
    final written = await _ref
        .read(summaryServiceProvider)
        .mutateBlocks(
          sessionId: sessionId,
          messages: messages,
          change: (blocks) => change(blocks, messages),
        );
    if (written) _notifyChanged();
    return written;
  }

  /// Drops stale blocks before anything is planned on top of them.
  Future<List<SummaryBlock>> _cleanBlocks(
    String sessionId,
    List<ChatMessage> messages,
  ) async {
    var cleaned = const <SummaryBlock>[];
    final written = await _ref
        .read(summaryServiceProvider)
        .mutateBlocks(
          sessionId: sessionId,
          messages: messages,
          change: (blocks) {
            cleaned = SummaryChain.withoutStale(blocks, messages);
            return identical(cleaned, blocks) ? null : cleaned;
          },
        );
    if (written) _notifyChanged();
    return cleaned;
  }

  void _notifyChanged() {
    if (!_ref.mounted) return;
    _ref.read(summaryRevisionProvider.notifier).state++;
  }

  Future<T> _exclusive<T>(String sessionId, Future<T> Function() run) async {
    if (!_running.add(sessionId)) {
      throw const SummaryChainException('busy');
    }
    try {
      return await run();
    } finally {
      _running.remove(sessionId);
    }
  }

  /// The session's messages as stored now — a run outlives the copy it was
  /// started with.
  Future<List<ChatMessage>> _messages(
    String sessionId,
    List<ChatMessage> fallback,
  ) async {
    final stored = await _ref.read(chatRepoProvider).getById(sessionId);
    return stored?.messages ?? fallback;
  }

  /// What the main prompt may use, and how much of it is neither history nor
  /// summary. Taken from the last prompt build when there is one: it carries
  /// the real preset, lorebooks and memory. Without one, only the connection
  /// is known and the fixed part counts as zero.
  _PromptBudget _promptBudget(String charId) {
    final breakdown = _ref.read(cachedTokenBreakdownProvider(charId));
    if (breakdown != null) {
      final total =
          breakdown.historyBudget +
          breakdown.fixedTotal -
          breakdown.vectorLoreTokens;
      if (total > 0) {
        // The builder counts the summary text it was handed under this key,
        // whichever block carried it.
        final summaryNow = breakdown.macroTokens['summary'] ?? 0;
        final fixed =
            breakdown.totalTokens - breakdown.historyTokens - summaryNow;
        return _PromptBudget(total: total, fixedTokens: math.max(0, fixed));
      }
    }
    final chat = _ref.read(activeApiConfigProvider);
    final total = chat == null ? 0 : chat.contextSize - chat.maxTokens;
    return _PromptBudget(total: total > 0 ? total : 32000, fixedTokens: 0);
  }

  /// The raw history an automatic run leaves as written: what fits under the
  /// line the run compacts to ([compactToTokens], the trigger at most) next
  /// to the fixed part and the live summary, so the run brings the prompt
  /// under that line. Counting the tail from the window instead (the rest
  /// past the trigger) let a prompt with a large fixed part — preset,
  /// lorebooks, memory — sit far above the trigger with nothing to retell,
  /// until the history trim cut it first.
  ///
  /// Never less than [SummaryCompactionSettings.autoTailFloorPercent] of
  /// [total]: a fixed part past the line cannot be compacted away, and the
  /// newest exchanges still have to reach the model as written.
  @visibleForTesting
  static int autoTailBudget({
    required int total,
    required int compactToTokens,
    required int fixedTokens,
    required int summaryTokens,
  }) => math.max(
    compactToTokens - fixedTokens - summaryTokens,
    total * SummaryCompactionSettings.autoTailFloorPercent ~/ 100,
  );

  /// The chat connection's context size, which a manual tail in percent is a
  /// share of; the prompt budget when no connection is set.
  int _contextSize(_PromptBudget budget) {
    final size = _ref.read(activeApiConfigProvider)?.contextSize ?? 0;
    return size > 0 ? size : budget.total;
  }

  /// How much transcript one summarizer request may carry: its window, less
  /// the answer and room for the instructions.
  static int _summarizerInputCap(ApiConfig config) {
    final output = config.maxTokens > 0 ? config.maxTokens : 4096;
    return (config.contextSize - output - 2000).clamp(2000, 60000);
  }

  /// A small source gets a small block; the setting is the ceiling.
  static int _targetFor(int sourceTokens, SummaryCompactionSettings settings) =>
      math.min(settings.blockTargetTokens, math.max(150, sourceTokens ~/ 3));

  static int _idSeq = 0;

  static String _newId() =>
      'sum-${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  Future<ApiConfig> _requireConfig(MemoryBookApiSettings slot) async {
    final apiConfig = await _resolveConfig(slot);
    if (apiConfig == null || apiConfig.mode == 'embedding') {
      throw Exception(
        'No chat API config found. Add one in API Settings first.',
      );
    }
    return apiConfig;
  }

  /// The Memory slot's connection, as one [ApiConfig] the summary can run on:
  /// the saved connection with the slot's model and output cap folded in, or —
  /// on the custom-endpoint branch — the endpoint the slot carries itself.
  Future<ApiConfig?> _resolveConfig(MemoryBookApiSettings slot) async {
    if (slot.generationSource == 'custom') {
      if (slot.generationEndpoint.isEmpty || slot.generationModel.isEmpty) {
        return null;
      }
      return ApiConfig(
        id: 'memory-slot-custom',
        endpoint: slot.generationEndpoint,
        apiKey: slot.generationApiKey,
        model: slot.generationModel,
        protocol: LlmProtocol.customChatCompletion,
        maxTokens: slot.generationMaxTokens ?? 0,
      );
    }
    // apiListProvider can still be loading on a cold start; the active config
    // the slot falls back to reads null until it resolves.
    await _ref.read(apiListProvider.future);
    final resolver = MemoryBookApiConfigResolver(
      apiConfigs: _ref.read(apiListProvider).value ?? const [],
      activeConfig: _ref.read(activeApiConfigProvider),
    );
    final config = resolver.resolve(slot);
    if (config == null) return null;
    return config.copyWith(
      model: slot.generationModel.isNotEmpty
          ? slot.generationModel
          : config.model,
      maxTokens: MemoryBookApiConfigResolver.maxTokensFor(slot, config),
    );
  }

  MacroContext _macroContext({
    required String charId,
    required ChatSession session,
  }) {
    final character = _ref.read(characterByIdProvider(charId));
    final persona = _ref.read(
      effectivePersonaForChatProvider((charId: charId, sessionId: session.id)),
    );
    return MacroContext(
      charName: character?.name ?? 'Character',
      charDescription: character?.description,
      charScenario: character?.scenario,
      charPersonality: character?.personality,
      charMesExample: character?.mesExample,
      macroName: character?.macroName,
      userName: persona?.name ?? 'User',
      personaPrompt: persona?.prompt,
      sessionVars: session.sessionVars,
      globalVars: _ref.read(globalVarsProvider),
      charId: charId,
      sessionId: session.id,
    );
  }
}

class _PromptBudget {
  final int total;
  final int fixedTokens;

  const _PromptBudget({required this.total, required this.fixedTokens});
}
