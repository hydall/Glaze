import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/macro_engine.dart';
import '../../../core/llm/memory_book_api_config_resolver.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/llm/transport/llm_protocol.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book_api_settings.dart';
import '../../../core/models/summary_block.dart';
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

/// Keeps the chat's summary chain in shape and runs every change to it.
///
/// Compaction is driven by how full the prompt is, not by a message count —
/// messages range from a line to a page, so a count says little about room.
/// Once the prompt passes the trigger share of what it may use, the oldest
/// messages outside the fresh tail are retold as a level-1 block, which then
/// stands in for them. When the live blocks themselves outgrow their share,
/// adjacent blocks of one level are merged a level up.
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

  /// Upper bound on steps per run, so a summarizer that keeps returning
  /// oversized text cannot loop.
  static const _maxSteps = 12;

  /// Compacts [session] until the prompt is back under the trigger. [force]
  /// ignores the trigger and the minimum run size: everything older than the
  /// fresh tail is summarized.
  ///
  /// Throws [SummaryChainException] `busy` when a run is already going, and
  /// whatever the transport throws.
  Future<SummaryCompactionResult> compact({
    required String charId,
    required ChatSession session,
    bool force = false,
    CancelToken? cancelToken,
  }) {
    return _exclusive(session.id, () async {
      final settings = await _ref.read(
        summaryCompactionSettingsProvider.future,
      );
      final slot = _ref.read(pipelineSettingsProvider).memoryBookApi;
      final apiConfig = await _requireConfig(slot);
      final service = _ref.read(summaryServiceProvider);
      final template = await service.getSummaryPrompt(session.id);
      final inputCap = _summarizerInputCap(apiConfig);

      var messages = await _messages(session.id, session.messages);
      final budget = _promptBudget(charId);
      var created = 0;
      var merged = 0;

      for (var step = 0; step < _maxSteps; step++) {
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
            await _merge(
              sessionId: session.id,
              parts: parts,
              messages: messages,
              apiConfig: apiConfig,
              settings: settings,
              temperature: slot.generationTemperature,
              cancelToken: cancelToken,
            );
            merged++;
            continue;
          }
        }

        final triggerTokens = budget.total * settings.triggerPercent ~/ 100;
        if (!force && used < triggerTokens) break;
        final plan = SummaryChain.planSource(
          blocks: blocks,
          messages: messages,
          tailBudgetTokens: budget.total - triggerTokens,
          maxSourceTokens: inputCap,
        );
        if (plan.source.isEmpty) break;
        final overflow = used > budget.total;
        final minSource = math.max(1000, settings.blockTargetTokens * 2);
        if (!force && !overflow && plan.sourceTokens < minSource) break;
        final target = _targetFor(plan.sourceTokens, settings);
        // A block barely smaller than its messages frees nothing.
        if (target * 11 ~/ 10 >= plan.sourceTokens) break;

        final firstSource = messages.indexWhere(
          (m) => m.id == plan.source.first.id,
        );
        final position = {
          for (var i = 0; i < messages.length; i++) messages[i].id: i,
        };
        final earlier = SummaryChain.live(blocks, messages).where(
          (b) =>
              b.isNote ||
              b.messageIds.any((id) => (position[id] ?? -1) < firstSource),
        );

        final text = await service.summarizeMessages(
          sessionId: session.id,
          source: plan.source,
          apiConfig: apiConfig,
          targetTokens: target,
          earlierSummary: SummaryChain.render(earlier),
          customPrompt: template,
          macroContext: _macroContext(charId: charId, session: session),
          cancelToken: cancelToken,
          temperature: slot.generationTemperature,
        );
        final tokens = estimateTokens(text);
        if (tokens >= plan.sourceTokens) {
          throw const SummaryChainException('not_shorter');
        }
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
          continue;
        }
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
        temperature: slot.generationTemperature,
        cancelToken: cancelToken,
      );
    });
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
          cancelToken: cancelToken,
          temperature: temperature,
        );
    final tokens = estimateTokens(text);
    if (tokens >= sourceTokens) {
      throw const SummaryChainException('not_shorter');
    }
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

  /// Reads the blocks and messages fresh, applies [change] and saves. A null
  /// from [change] skips the write. Returns whether anything was written.
  Future<bool> _commit(
    String sessionId,
    List<ChatMessage> fallbackMessages,
    List<SummaryBlock>? Function(
      List<SummaryBlock> blocks,
      List<ChatMessage> messages,
    )
    change,
  ) async {
    final service = _ref.read(summaryServiceProvider);
    final messages = await _messages(sessionId, fallbackMessages);
    final next = change(await service.getBlocks(sessionId), messages);
    if (next == null) return false;
    await service.saveBlocks(
      sessionId: sessionId,
      blocks: next,
      messages: messages,
    );
    _notifyChanged();
    return true;
  }

  /// Drops stale blocks before anything is planned on top of them.
  Future<List<SummaryBlock>> _cleanBlocks(
    String sessionId,
    List<ChatMessage> messages,
  ) async {
    final service = _ref.read(summaryServiceProvider);
    final blocks = await service.getBlocks(sessionId);
    final cleaned = SummaryChain.withoutStale(blocks, messages);
    if (!identical(cleaned, blocks)) {
      await service.saveBlocks(
        sessionId: sessionId,
        blocks: cleaned,
        messages: messages,
      );
      _notifyChanged();
    }
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
