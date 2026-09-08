import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../models/api_config.dart';
import '../models/character.dart';
import '../models/chat_message.dart';
import '../utils/cast_helpers.dart';
import '../models/lorebook.dart';
import '../models/memory_book.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import '../models/tracker.dart';
import '../state/active_selection_provider.dart';
import '../state/db_provider.dart';
import '../state/global_regex_provider.dart';
import '../state/lorebook_embedding_provider.dart';
import '../state/lorebook_provider.dart';
import '../state/memory_settings_provider.dart';
import '../state/summary_providers.dart';
import 'memory_injection_service.dart';
import 'message_recall_service.dart';
import 'memory_selector.dart';
import 'prompt_builder.dart';
import 'prompt/arc_state_builder.dart';
import 'prompt/ledger_tracker_loader.dart';
import 'prompt/lorebook_vector_searcher.dart';
import 'prompt/studio_session_state_compiler.dart';
import 'knowledge/character_knowledge_projection.dart';
import 'prompt_inputs.dart';
import 'prompt_inputs_collector.dart';

// Re-export for backward compat — tests import this from here.
export 'prompt/studio_session_state_compiler.dart'
    show kCompileStudioSessionStateForTest;

class PromptPayloadBuilder {
  final Ref _ref;
  final Future<List<Tracker>> Function(String sessionId)
  _loadEffectiveLedgerTrackers;
  final PromptInputsCollector _inputsCollector;
  final ApiConfigInitializer _initializeApiConfigs;
  final ActiveApiConfigReader _readActiveApiConfig;
  final PromptHistoryInjector _injectHistory;
  final RuntimePromptBlocksReader _readRuntimePromptBlocks;
  late final LorebookVectorSearcher _vectorSearcher = LorebookVectorSearcher(
    _ref,
    onDiagnostic: onLorebookVectorSearchDiagnostic,
  );

  final void Function(LorebookVectorSearchDiagnostic diagnostic)?
  onLorebookVectorSearchDiagnostic;

  factory PromptPayloadBuilder(
    Ref ref, {
    required PromptInputsCollector inputsCollector,
    required ApiConfigInitializer initializeApiConfigs,
    required ActiveApiConfigReader readActiveApiConfig,
    required PromptHistoryInjector injectHistory,
    required RuntimePromptBlocksReader readRuntimePromptBlocks,
    Future<List<Tracker>> Function(String sessionId)?
    loadEffectiveLedgerTrackers,
    void Function(LorebookVectorSearchDiagnostic diagnostic)?
    onLorebookVectorSearchDiagnostic,
  }) => PromptPayloadBuilder._(
    ref,
    inputsCollector,
    initializeApiConfigs,
    readActiveApiConfig,
    injectHistory,
    readRuntimePromptBlocks,
    loadEffectiveLedgerTrackers ??
        LedgerTrackerLoader(ref).loadEffectiveLedgerTrackers,
    onLorebookVectorSearchDiagnostic,
  );

  PromptPayloadBuilder._(
    this._ref,
    this._inputsCollector,
    this._initializeApiConfigs,
    this._readActiveApiConfig,
    this._injectHistory,
    this._readRuntimePromptBlocks,
    this._loadEffectiveLedgerTrackers,
    this.onLorebookVectorSearchDiagnostic,
  );

  /// Collects raw inputs from DB/providers for isolate-based processing.
  /// Fast path: DB reads only, no memory injection or vector search.
  /// Delegates to [PromptInputsCollector].
  Future<PromptInputs> collectInputs({
    required String charId,
    required ChatSession? session,
    String? guidanceText,
  }) => _inputsCollector.collectInputs(
    charId: charId,
    session: session,
    guidanceText: guidanceText,
  );

  Future<PromptPayload> buildFromSession({
    required String charId,
    required ChatSession? session,
    ApiConfig? apiConfigOverride,
    String? guidanceText,
    bool skipVectorSearch = false,
    bool Function()? shouldAbort,
    CancelToken? cancelToken,
  }) async {
    void throwIfAborted() {
      if (shouldAbort?.call() == true) {
        throw const _GenerationAbortedException();
      }
    }

    throwIfAborted();
    final charRepo = _ref.read(characterRepoProvider);
    final presetRepo = _ref.read(presetRepoProvider);
    final personaRepo = _ref.read(personaRepoProvider);
    final lorebookRepo = _ref.read(lorebookRepoProvider);

    final character = await charRepo.getById(charId);
    throwIfAborted();
    if (character == null) throw StateError('Character not found: $charId');

    await _initializeApiConfigs();
    throwIfAborted();
    final chatApi = apiConfigOverride ?? _readActiveApiConfig();
    if (chatApi == null || chatApi.mode == 'embedding') {
      throw StateError('No chat API config available');
    }

    final activePresetId = _ref.read(activePresetIdProvider);
    final presets = await presetRepo.getAll();
    throwIfAborted();
    final preset = activePresetId != null
        ? presets.where((p) => p.id == activePresetId).firstOrNull
        : (presets.isNotEmpty ? presets.first : null);

    final personas = await personaRepo.getAll();
    throwIfAborted();
    final connections = _ref.read(personaConnectionsProvider);
    final activePersonaId = _ref.read(activePersonaIdProvider);
    final sessionId = session?.id;

    final persona = getEffectivePersona(
      personas,
      charId,
      sessionId,
      activePersonaId,
      connections,
    );

    final lorebooks = await lorebookRepo.getAll();
    throwIfAborted();
    final lorebookSettings = _ref.read(lorebookSettingsProvider);
    final lorebookActivations = _ref.read(lorebookActivationsProvider);

    String? summaryContent;
    Map<String, dynamic> memoryCoverage = {};
    List<TriggeredEntry> triggeredMemories = [];
    List<RuntimePromptBlock> runtimePromptBlocks = const [];
    List<ChatMessage> history = session?.messages ?? [];
    Map<String, String> sessionVars = session?.sessionVars ?? {};
    List<LorebookEntry> vectorEntries = [];
    MemorySelection? memorySelection;
    var memoryInjectionTarget = 'hard_block';
    // NEW (patch #3): raw-message recall content for <recalled_messages>.
    String? recalledMessagesContent;
    List<RecalledMessageChunk> recalledMessageChunks = const [];
    final g = _ref.read(memoryGlobalSettingsProvider);
    MemoryBook? memoryBook;
    var memoryGraphEnabled = g.enabled;
    if (memoryGraphEnabled && sessionId != null) {
      memoryBook = await _ref
          .read(memoryBookRepoProvider)
          .getBySessionId(sessionId);
      throwIfAborted();
      memoryGraphEnabled = memoryBook?.settings.enabled ?? true;
    }
    var memorySettings = MemoryBookSettings(
      enabled: g.enabled,
      memoryExcerptingEnabled: g.memoryExcerptingEnabled,
      memoryPackingMode: g.memoryPackingMode,
      memoryExcerptTokensPerChunk: g.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: g.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: g.chunkFirstTopEntries,
      chunkFirstTopChunks: g.chunkFirstTopChunks,
    );

    if (session != null) {
      history = await _injectHistory(sessionId: session.id, messages: history);
      throwIfAborted();
      runtimePromptBlocks = _readRuntimePromptBlocks(session.id);

      final summaryService = _ref.read(summaryServiceProvider);
      summaryContent = await summaryService.getSummary(session.id);
      throwIfAborted();

      final memoryService = _ref.read(memoryInjectionServiceProvider);
      final embeddingConfig = _ref.read(embeddingConfigProvider);
      final currentText = session.messages.lastOrNull?.content ?? '';

      // Run memory candidate collection and lorebook vector search in
      // parallel. They hit different data sources and are independent;
      // sequential execution doubles wall-clock time when the embedding
      // endpoint is slow. The final memory refilter against the visible
      // window happens later inside buildPrompt (see
      // docs/INVARIANTS.md §5.5).
      final lorebookFuture = (!skipVectorSearch)
          ? _vectorSearcher
                .search(
                  session.messages,
                  currentText,
                  character.world,
                  character,
                  chatId: session.id,
                  cancelToken: cancelToken,
                )
                .timeout(const Duration(seconds: 30), onTimeout: () => const [])
          : Future<List<LorebookEntry>>.value(const []);

      final memoryFuture = memoryGraphEnabled && memoryBook != null
          ? memoryService.buildCandidatesWithDiagnostics(
              sessionId: session.id,
              history: session.messages,
              currentText: currentText,
              embeddingConfig: embeddingConfig,
              shouldAbort: shouldAbort,
              cancelToken: cancelToken,
              contextBudgetTokens: chatApi.contextSize,
            )
          : Future.value(
              MemoryCandidateBuildResult(
                selection: const MemorySelection(),
                diagnostics: null,
                settings: memoryBook?.settings,
              ),
            );

      // NEW (patch #3): raw-message recall — cosine search over
      // `sourceType='chat_message'` chunks embedded by
      // ChatMessageEmbeddingService after each generation. Lossless
      // backstop for the lossy MemoryBook compression. Empty / no-op when
      // embeddingConfig.endpoint is empty or no chunks exist yet.
      // Rationale (patch #3): raw-message recall is a lossless backstop for
      // the lossy MemoryBook compression — chunk=5 messages → cosine search →
      // `<recalled_messages>` injection (Marinara memory-recall analog).
      final recallFuture = _ref
          .read(messageRecallServiceProvider)
          .recall(
            sessionId: session.id,
            currentText: currentText,
            config: embeddingConfig,
            cancelToken: cancelToken,
            shouldAbort: shouldAbort,
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => const MessageRecallResult(),
          );

      throwIfAborted();
      final results = await Future.wait([
        memoryFuture,
        lorebookFuture,
        recallFuture,
      ]);
      throwIfAborted();
      final memoryResult = results[0] as MemoryCandidateBuildResult;
      memorySelection = memoryResult.selection;
      memorySettings = memoryResult.settings ?? memorySettings;
      memoryInjectionTarget = memorySettings.injectionTarget == 'macro'
          ? 'macro'
          : 'hard_block';
      vectorEntries = results[1] as List<LorebookEntry>;
      final recallResult = results[2] as MessageRecallResult;
      if (recallResult.matches.isNotEmpty) {
        final block = StringBuffer();
        block.writeln('<recalled_messages>');
        block.writeln(
          'Semantically relevant raw message chunks from earlier in this chat. '
          'Do not explicitly reference "remembering" these — use them as ground '
          'truth context.',
        );
        for (final match in recallResult.matches) {
          block.writeln('---');
          block.writeln(match.text);
        }
        block.writeln('</recalled_messages>');
        recalledMessagesContent = block.toString();
        recalledMessageChunks = recallResult.matches
            .map(
              (m) =>
                  RecalledMessageChunk(text: m.text, messageIds: m.messageIds),
            )
            .toList(growable: false);
      }
      throwIfAborted();
      memoryCoverage = {
        'entryIds': memorySelection.entries.map((e) => e.id).toList(),
        'needsRebuild': false,
        'stale': false,
        'injected': false,
        'candidatesTotal': memorySelection.allScores.length,
        'excludedBySourceWindow': memorySelection.excludedBySourceWindow,
        'budgetTokens': memorySelection.budgetTokens,
        'budgetTrimmed': memorySelection.budgetTrimmed,
        'packingMode': memorySettings.memoryPackingMode,
        'excerptTokensPerChunk': memorySettings.memoryExcerptTokensPerChunk,
        'excerptChunksPerEntry': memorySettings.memoryExcerptChunksPerEntry,
        'chunkFirstTopEntries': memorySettings.chunkFirstTopEntries,
        'chunkFirstTopChunks': memorySettings.chunkFirstTopChunks,
        if (memoryResult.diagnostics != null)
          'diagnostics': memoryResult.diagnostics!.toJson(),
      };
      if (memorySelection.entries.isNotEmpty) {
        triggeredMemories = memorySelection.entries
            .map(
              (e) => TriggeredEntry(
                id: e.id,
                name: e.title.isNotEmpty ? e.title : e.id,
                source: 'memory',
              ),
            )
            .toList();
      }
      // NEW (patch #4 follow-up): chatSummaryFingerprint analog for
      // prompt cache invalidation. Hash the canonical serialization of
      // the selected memory entries (id + content) so the next generation
      // can detect "memory changed since last turn" and invalidate
      // Anthropic/DeepSeek prompt cache. Note: this is a simpler hash than
      // the isolate-path's `computeHash(memoryContent)` because here we
      // do not have the compiled memory injection content (it is built
      // later in the prompt builder from the excerpt selection). The
      // id+content hash is sufficient for cache invalidation — any
      // change to the selected entries' content (append-only newFacts,
      // user edits, agent writes) changes the fingerprint.
      // Rationale: MemoryBook IS our summary (no separate Chat Summary system).
      // The fingerprint (djb2-style hash of id:content pairs) detects "memory
      // changed since last turn" for prompt-cache invalidation — any change
      // to selected entries' content changes the fingerprint (Marinara
      // chatSummaryFingerprint analog).
      final fingerprintBase = memorySelection.entries.isNotEmpty
          ? memorySelection.entries
                .map((e) => '${e.id}:${e.content}')
                .join('||')
          : '';
      final memoryInjectionFingerprint = fingerprintBase.isNotEmpty
          ? computeHash(fingerprintBase)
          : '';
      memoryCoverage['memoryInjectionFingerprint'] = memoryInjectionFingerprint;
    }

    // Load committed Studio Ledger canon state from tracker_rows and compile
    // the <studio_session_state> injection block. Loaded whenever Studio Ledger
    // is enabled, regardless of memoryMode. Falls back to null on any error.
    // Rationale: inject committed canon state (entity/relationship/arc/world)
    // as hidden/system prompt so the LLM sees session canon overriding
    // character-card baseline. Priority-based budget: manual overrides/locks
    // and conflict-preventing canon overrides are never trimmed before raw
    // recall or optional InfBlocks.
    String? studioSessionStateContent;
    String? characterKnowledgeContent;
    List<Tracker>? ledgerTrackers;
    if (memoryGraphEnabled && sessionId != null) {
      try {
        final facts = await _ref
            .read(characterKnowledgeFactRepoProvider)
            .getActiveForSession(sessionId);
        characterKnowledgeContent = compileCharacterKnowledgeProjection(
          facts,
          latestUserText: latestUserTextFromHistory(history),
          latestAssistantText: latestAssistantTextFromHistory(history),
        );
      } catch (e) {
        debugPrint('[PromptBuilder] character knowledge load failed: $e');
      }
    }
    if (memoryGraphEnabled && sessionId != null) {
      try {
        ledgerTrackers = List.unmodifiable(
          await _loadEffectiveLedgerTrackers(sessionId),
        );
      } catch (e) {
        debugPrint('[PromptBuilder] studio_session_state load failed: $e');
      }
      try {
        if (ledgerTrackers case final ledgerTrackers?
            when ledgerTrackers.isNotEmpty) {
          studioSessionStateContent = compileStudioSessionState(
            ledgerTrackers,
            sessionId,
            latestUserText: latestUserTextFromHistory(history),
            latestAssistantText: latestAssistantTextFromHistory(history),
          );
        }
      } catch (e) {
        debugPrint('[PromptBuilder] studio_session_state load failed: $e');
      }
    }

    // Load {{arc}} macro content from Studio Canon arc:* tracker rows.
    // Falls back to null when Studio Ledger has not written any arc state yet
    // (e.g. memoryMode=fast or first turn). Does NOT use the old
    // memory_consolidation_rows — those are disconnected from Studio Canon.
    // Rationale: {{arc}} renders selected arc:* state from Studio Canon (not
    // the old consolidation rows). Selection: arcs linked to entities/topics
    // mentioned in the latest user message, arcs that override card hooks,
    // prefer active arcs and completed arcs with do_not_reopen=true. Omit
    // unrelated completed arcs unless needed to prevent card-baseline regression.
    String? arcContent;
    String? entitiesContent;
    if (memoryGraphEnabled &&
        memorySettings.memoryMode != 'fast' &&
        sessionId != null) {
      try {
        if (ledgerTrackers != null) {
          arcContent = buildArcContent(
            ledgerTrackers,
            latestUserText: latestUserTextFromHistory(history),
            latestAssistantText: latestAssistantTextFromHistory(history),
          );
        }
      } catch (_) {}
      try {
        final entities = await _ref
            .read(memoryEntityRepoProvider)
            .getBySessionId(sessionId);
        if (entities.isNotEmpty) {
          final active = entities.where((e) => e.status == 'active').take(20);
          entitiesContent = active
              .map(
                (e) =>
                    '- ${e.name} (${e.entityType})'
                    '${e.facts.isNotEmpty ? ": ${e.facts.join("; ")}" : ""}',
              )
              .join('\n');
        }
      } catch (_) {}
    }

    return PromptPayload(
      character: character,
      persona: persona,
      preset: preset,
      history: history,
      sessionId: sessionId,
      apiConfig: chatApi,
      sessionVars: sessionVars,
      globalVars: _ref.read(globalVarsProvider),
      lorebooks: lorebooks,
      lorebookSettings: lorebookSettings,
      lorebookActivations: lorebookActivations,
      vectorEntries: vectorEntries,
      summaryContent: summaryContent,
      memoryContent: null,
      memoryMacroContent: null,
      memoryInjectionTarget: memoryInjectionTarget,
      memoryCoverage: memoryCoverage,
      guidanceText: guidanceText,
      authorsNote: session?.authorsNote,
      characterDepthPrompt: character.depthPrompt,
      characterDepthPromptDepth: character.depthPromptDepth,
      characterDepthPromptRole: character.depthPromptRole,
      globalRegexes: _ref.read(globalRegexProvider).value ?? [],
      triggeredMemories: triggeredMemories,
      runtimePromptBlocks: runtimePromptBlocks,
      memorySelection: memorySelection,
      memoryExcerptingEnabled: memorySettings.memoryExcerptingEnabled,
      memoryPackingMode: memorySettings.memoryPackingMode,
      memoryExcerptTokensPerChunk: memorySettings.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: memorySettings.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: memorySettings.chunkFirstTopEntries,
      chunkFirstTopChunks: memorySettings.chunkFirstTopChunks,
      arcContent: arcContent,
      entitiesContent: entitiesContent,
      studioSessionStateContent: studioSessionStateContent,
      characterKnowledgeContent: characterKnowledgeContent,
      recalledMessagesContent: recalledMessagesContent,
      recalledMessageChunks: recalledMessageChunks,
    );
  }

  Future<PromptPayload> buildFromPreFetched({
    required String charId,
    required ChatSession? session,
    required Character character,
    required ApiConfig chatApi,
    required Preset? preset,
    required Persona? persona,
    required List<Lorebook> lorebooks,
    String? summaryContent,
    String? memoryContent,
    String? memoryMacroContent,
    String memoryInjectionTarget = 'hard_block',
    Map<String, dynamic> memoryCoverage = const {},
    List<TriggeredEntry> triggeredMemories = const [],
    String? guidanceText,
    bool skipVectorSearch = true,
    List<RuntimePromptBlock> runtimePromptBlocks = const [],
    String? recalledMessagesContent,
  }) async {
    final lorebookSettings = _ref.read(lorebookSettingsProvider);
    final lorebookActivations = _ref.read(lorebookActivationsProvider);

    List<LorebookEntry> vectorEntries = [];
    List<ChatMessage> history = session?.messages ?? [];
    if (session != null) {
      history = await _injectHistory(sessionId: session.id, messages: history);
    }
    if (!skipVectorSearch && session != null) {
      vectorEntries = await _vectorSearcher.search(
        history,
        history.lastOrNull?.content ?? '',
        character.world,
        character,
        chatId: session.id,
      );
    }

    final memSettings = _ref.read(memoryGlobalSettingsProvider);
    MemoryBook? memoryBook;
    var memoryGraphEnabled = memSettings.enabled;
    if (memoryGraphEnabled && session != null) {
      memoryBook = await _ref
          .read(memoryBookRepoProvider)
          .getBySessionId(session.id);
      memoryGraphEnabled = memoryBook?.settings.enabled ?? true;
    }
    String? studioSessionStateContent;
    List<Tracker>? ledgerTrackers;
    if (memoryGraphEnabled && session != null) {
      try {
        ledgerTrackers = List.unmodifiable(
          await _loadEffectiveLedgerTrackers(session.id),
        );
      } catch (e) {
        debugPrint('[PromptBuilder] studio_session_state load failed: $e');
      }
      try {
        if (ledgerTrackers case final ledgerTrackers?
            when ledgerTrackers.isNotEmpty) {
          studioSessionStateContent = compileStudioSessionState(
            ledgerTrackers,
            session.id,
            latestUserText: latestUserTextFromHistory(history),
            latestAssistantText: latestAssistantTextFromHistory(history),
          );
        }
      } catch (e) {
        debugPrint('[PromptBuilder] studio_session_state load failed: $e');
      }
    }
    String? arcContent;
    String? entitiesContent;
    if (memoryGraphEnabled &&
        (memoryBook?.settings.memoryMode ?? memSettings.memoryMode) != 'fast' &&
        session != null) {
      try {
        if (ledgerTrackers != null) {
          arcContent = buildArcContent(
            ledgerTrackers,
            latestUserText: latestUserTextFromHistory(history),
            latestAssistantText: latestAssistantTextFromHistory(history),
          );
        }
      } catch (_) {}
      try {
        final entities = await _ref
            .read(memoryEntityRepoProvider)
            .getBySessionId(session.id);
        if (entities.isNotEmpty) {
          final active = entities.where((e) => e.status == 'active').take(20);
          entitiesContent = active
              .map(
                (e) =>
                    '- ${e.name} (${e.entityType})'
                    '${e.facts.isNotEmpty ? ": ${e.facts.join("; ")}" : ""}',
              )
              .join('\n');
        }
      } catch (_) {}
    }

    return PromptPayload(
      character: character,
      persona: persona,
      preset: preset,
      history: history,
      sessionId: session?.id,
      apiConfig: chatApi,
      sessionVars: session?.sessionVars ?? {},
      globalVars: _ref.read(globalVarsProvider),
      lorebooks: lorebooks,
      lorebookSettings: lorebookSettings,
      lorebookActivations: lorebookActivations,
      vectorEntries: vectorEntries,
      summaryContent: summaryContent,
      memoryContent: memoryContent,
      memoryMacroContent: memoryMacroContent,
      memoryInjectionTarget: memoryInjectionTarget,
      memoryCoverage: memoryCoverage,
      guidanceText: guidanceText,
      authorsNote: session?.authorsNote,
      characterDepthPrompt: character.depthPrompt,
      characterDepthPromptDepth: character.depthPromptDepth,
      characterDepthPromptRole: character.depthPromptRole,
      globalRegexes: _ref.read(globalRegexProvider).value ?? [],
      triggeredMemories: triggeredMemories,
      runtimePromptBlocks: runtimePromptBlocks,
      memoryExcerptingEnabled: memSettings.memoryExcerptingEnabled,
      memoryPackingMode: memSettings.memoryPackingMode,
      memoryExcerptTokensPerChunk: memSettings.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: memSettings.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: memSettings.chunkFirstTopEntries,
      chunkFirstTopChunks: memSettings.chunkFirstTopChunks,
      arcContent: arcContent,
      entitiesContent: entitiesContent,
      studioSessionStateContent: studioSessionStateContent,
      recalledMessagesContent: recalledMessagesContent,
      recalledMessageChunks: const [],
    );
  }
}

class _GenerationAbortedException implements Exception {
  const _GenerationAbortedException();
}
