import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../models/api_config.dart';
import '../db/repositories/session_lorebook_evolution_repo.dart';
import '../models/character.dart';
import '../models/chat_message.dart';
import '../utils/cast_helpers.dart';
import '../models/lorebook.dart';
import '../models/memory_book.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import '../models/tracker.dart';
import '../models/ledger_prompt_injection_policy.dart';
import '../state/active_selection_provider.dart';
import '../state/db_provider.dart';
import '../state/global_regex_provider.dart';
import '../state/lorebook_embedding_provider.dart';
import '../state/lorebook_provider.dart';
import '../state/memory_settings_provider.dart';
import '../state/summary_providers.dart';
import 'memory_injection_service.dart';
import 'memory_retrieval_mode.dart';
import 'game_time.dart';
import 'message_recall_service.dart';
import 'memory_selector.dart';
import 'generation_context_inputs.dart';
import 'prompt_builder.dart';
import 'prompt/arc_state_builder.dart';
import 'prompt/ledger_tracker_loader.dart';
import 'prompt/lorebook_vector_searcher.dart';
import 'prompt_inputs.dart';
import 'prompt_inputs_collector.dart';
import 'prompt/effective_canon_prompt_formatter.dart';
import 'prompt/effective_canon_prompt_materializer.dart';
import 'prompt/selective_ledger_projection_filter.dart';
import '../services/card_rewriter/effective_canon_context_loader.dart';
import 'prompt/prompt_build_stale_exception.dart';

// Re-export for backward compat — tests import this from here.
export 'prompt/studio_session_state_compiler.dart'
    show kCompileStudioSessionStateForTest;

class PromptPayloadBuilder {
  final Ref _ref;
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
    Future<List<Tracker>> Function(String sessionId) _,
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
    final inputs = await collectGenerationContext(
      charId: charId,
      session: session,
      apiConfigOverride: apiConfigOverride,
      guidanceText: guidanceText,
      skipVectorSearch: skipVectorSearch,
      shouldAbort: shouldAbort,
      cancelToken: cancelToken,
    );
    final preset = await _resolveOrdinaryPreset(shouldAbort: shouldAbort);
    return PromptPayload.fromGenerationContext(
      inputs,
      preset: preset,
      ledgerPromptInjectionPolicy: disabledLedgerPromptInjectionPolicy,
    );
  }

  Future<PromptPayload> buildOrdinaryFromGenerationContext(
    GenerationContextInputs inputs, {
    bool Function()? shouldAbort,
  }) async {
    final preset = await _resolveOrdinaryPreset(shouldAbort: shouldAbort);
    return PromptPayload.fromGenerationContext(
      inputs,
      preset: preset,
      ledgerPromptInjectionPolicy: disabledLedgerPromptInjectionPolicy,
    );
  }

  /// Collects all live generation source data without selecting or reading an
  /// ordinary preset. Request compilers attach their own typed configuration.
  Future<GenerationContextInputs> collectGenerationContext({
    required String charId,
    required ChatSession? session,
    ApiConfig? apiConfigOverride,
    String? guidanceText,
    bool skipVectorSearch = false,
    bool includeEffectiveCanon = false,
    bool readOnlyEffectiveCanon = false,
    bool allowRemoteRetrieval = true,
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
    final personaRepo = _ref.read(personaRepoProvider);
    final lorebookRepo = _ref.read(lorebookRepoProvider);

    final effectiveCharId = session?.characterId ?? charId;
    final sourceCharacter = await charRepo.getById(effectiveCharId);
    throwIfAborted();
    if (sourceCharacter == null) {
      throw StateError('Character not found: $effectiveCharId');
    }
    final effectiveContext = session == null || !includeEffectiveCanon
        ? null
        : readOnlyEffectiveCanon
        ? await _ref
              .read(effectiveCanonContextLoaderProvider)
              .loadReadOnly(
                sessionId: session.id,
                sourceCharacter: sourceCharacter,
              )
        : await _ref
              .read(effectiveCanonContextLoaderProvider)
              .load(sessionId: session.id, sourceCharacter: sourceCharacter);
    final character = effectiveContext?.character ?? sourceCharacter;
    final effectiveProjection = effectiveContext == null
        ? null
        : EffectiveCanonPromptProjection.fromContext(effectiveContext);

    await _initializeApiConfigs();
    throwIfAborted();
    final chatApi = apiConfigOverride ?? _readActiveApiConfig();
    if (chatApi == null || chatApi.mode == 'embedding') {
      throw StateError('No chat API config available');
    }

    final personas = await personaRepo.getAll();
    throwIfAborted();
    final connections = _ref.read(personaConnectionsProvider);
    final activePersonaId = _ref.read(activePersonaIdProvider);
    final sessionId = session?.id;

    final persona = getEffectivePersona(
      personas,
      effectiveCharId,
      sessionId,
      activePersonaId,
      connections,
    );

    final sourceLorebooks = await lorebookRepo.getAll();
    final effectiveLorebooks = session == null
        ? EffectiveSessionLorebooks(
            lorebooks: sourceLorebooks,
            overlayTargets: const {},
          )
        : await _ref
              .read(sessionLorebookEvolutionRepoProvider)
              .resolveEffectiveLorebooks(
                sessionId: session.id,
                lorebooks: sourceLorebooks,
              );
    final lorebooks = effectiveLorebooks.lorebooks;
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
      final lorebookFuture = (!skipVectorSearch && allowRemoteRetrieval)
          ? _vectorSearcher
                .search(
                  session.messages,
                  currentText,
                  character.world,
                  character,
                  lorebooks: lorebooks,
                  sessionOverlayTargets: effectiveLorebooks.overlayTargets,
                  chatId: session.id,
                  cancelToken: cancelToken,
                )
                .timeout(const Duration(seconds: 30), onTimeout: () => const [])
          : Future<List<LorebookEntry>>.value(const []);

      final memoryFuture =
          allowRemoteRetrieval && memoryGraphEnabled && memoryBook != null
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
      final recallFuture = allowRemoteRetrieval
          ? _ref
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
                )
          : Future.value(const MessageRecallResult());

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
    if (effectiveProjection != null && sessionId != null) {
      final canon = EffectiveCanonPromptFormatter.format(
        effectiveProjection,
        sessionId: sessionId,
        latestUserText: latestUserTextFromHistory(history),
        latestAssistantText: latestAssistantTextFromHistory(history),
      );
      characterKnowledgeContent = canon.characterKnowledge;
      studioSessionStateContent = canon.sessionState;
      ledgerTrackers = effectiveProjection.trackers;
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
        MemoryRetrievalMode.fromValue(
          memorySettings.memoryMode,
        ).supports(MemoryRetrievalCapability.extendedPromptContext) &&
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

    await _ensureEffectiveCanonCurrent(
      charId: effectiveCharId,
      session: session,
      context: effectiveContext,
    );
    final gameTimeState = GameTimeState.fromTrackers(
      ledgerTrackers ?? const <Tracker>[],
    );
    return GenerationContextInputs(
      character: character,
      persona: persona,
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
      gameTime: gameTimeState.time,
      gameDate: gameTimeState.date,
      gameDay: gameTimeState.day?.toString(),
      characterKnowledgeContent: characterKnowledgeContent,
      recalledMessagesContent: recalledMessagesContent,
      recalledMessageChunks: recalledMessageChunks,
      effectiveCanonProjection: effectiveProjection,
      effectiveCanonRevisionNumber: effectiveProjection?.revisionNumber,
      effectiveCanonRevisionHash: effectiveProjection?.revisionHash,
      effectiveCanonCacheIdentity: effectiveProjection?.cacheIdentity ?? '',
      // The projection was loaded from one effective-canon snapshot and
      // revalidated immediately above. Exact message/swipe provenance may now
      // be compared with the frozen final source window by each compiler.
      ledgerProjectionFreshnessProvenCurrent: effectiveContext != null,
    );
  }

  Future<Preset?> _resolveOrdinaryPreset({bool Function()? shouldAbort}) async {
    final activePresetId = _ref.read(activePresetIdProvider);
    final presets = await _ref.read(presetRepoProvider).getAll();
    if (shouldAbort?.call() == true) {
      throw const _GenerationAbortedException();
    }
    return activePresetId != null
        ? presets.where((p) => p.id == activePresetId).firstOrNull
        : presets.firstOrNull;
  }

  Future<PromptPayload> buildFromPreFetched({
    required String charId,
    required ChatSession? session,
    required Character character,
    EffectiveCanonContext? effectiveCanonContext,
    bool includeEffectiveCanon = false,
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
    final resolvedContext = !includeEffectiveCanon
        ? null
        : effectiveCanonContext ??
              (session != null
                  ? await _ref
                        .read(effectiveCanonContextLoaderProvider)
                        .load(sessionId: session.id, sourceCharacter: character)
                  : null);
    final projection = resolvedContext == null
        ? null
        : EffectiveCanonPromptProjection.fromContext(resolvedContext);
    // Never trust the caller's raw character for a session-scoped prompt.
    final effectiveCharacter = resolvedContext?.character ?? character;
    final lorebookSettings = _ref.read(lorebookSettingsProvider);
    final lorebookActivations = _ref.read(lorebookActivationsProvider);
    final effectiveLorebookSet = session == null
        ? EffectiveSessionLorebooks(
            lorebooks: lorebooks,
            overlayTargets: const {},
          )
        : await _ref
              .read(sessionLorebookEvolutionRepoProvider)
              .resolveEffectiveLorebooks(
                sessionId: session.id,
                lorebooks: lorebooks,
              );
    final effectiveLorebooks = effectiveLorebookSet.lorebooks;

    List<LorebookEntry> vectorEntries = [];
    List<ChatMessage> history = session?.messages ?? [];
    if (session != null) {
      history = await _injectHistory(sessionId: session.id, messages: history);
    }
    if (!skipVectorSearch && session != null) {
      vectorEntries = await _vectorSearcher.search(
        history,
        history.lastOrNull?.content ?? '',
        effectiveCharacter.world,
        effectiveCharacter,
        lorebooks: effectiveLorebooks,
        sessionOverlayTargets: effectiveLorebookSet.overlayTargets,
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
    const policy = disabledLedgerPromptInjectionPolicy;
    final materialized = projection == null || session == null
        ? null
        : EffectiveCanonPromptMaterializer.materializeSafely(
            SelectiveLedgerProjectionInput(
              policy: policy,
              consumerPath: 'prefetched',
              projection: projection,
              visibleMessages: history,
              selectedSwipeByMessageId: {
                for (final message in history) message.id: message.swipeId,
              },
              focalUserName:
                  session.messages.reversed
                      .map((message) => message.personaName?.trim())
                      .firstWhere(
                        (name) => name != null && name.isNotEmpty,
                        orElse: () => null,
                      ) ??
                  '',
            ),
            sessionId: session.id,
            latestUserText: latestUserTextFromHistory(history),
            latestAssistantText: latestAssistantTextFromHistory(history),
          );
    String? arcContent = materialized?.arcContent;
    String? entitiesContent;
    if (memoryGraphEnabled &&
        MemoryRetrievalMode.fromValue(
          memoryBook?.settings.memoryMode ?? memSettings.memoryMode,
        ).supports(MemoryRetrievalCapability.extendedPromptContext) &&
        session != null) {
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

    await _ensureEffectiveCanonCurrent(
      charId: charId,
      session: session,
      context: resolvedContext,
    );
    final gameTimeState = GameTimeState.fromTrackers(
      projection?.trackers ?? const <Tracker>[],
    );
    return PromptPayload(
      character: effectiveCharacter,
      persona: persona,
      preset: preset,
      history: history,
      sessionId: session?.id,
      apiConfig: chatApi,
      sessionVars: session?.sessionVars ?? {},
      globalVars: _ref.read(globalVarsProvider),
      lorebooks: effectiveLorebooks,
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
      characterDepthPrompt: effectiveCharacter.depthPrompt,
      characterDepthPromptDepth: effectiveCharacter.depthPromptDepth,
      characterDepthPromptRole: effectiveCharacter.depthPromptRole,
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
      studioSessionStateContent: materialized?.studioSessionStateContent,
      gameTime: gameTimeState.time,
      gameDate: gameTimeState.date,
      gameDay: gameTimeState.day?.toString(),
      characterKnowledgeContent: materialized?.characterKnowledgeContent,
      recalledMessagesContent: recalledMessagesContent,
      recalledMessageChunks: const [],
      effectiveCanonProjection: projection,
      effectiveCanonRevisionNumber: projection?.revisionNumber,
      effectiveCanonRevisionHash: projection?.revisionHash,
      effectiveCanonCacheIdentity: projection?.cacheIdentity ?? '',
      ledgerPromptInjectionPolicy: policy,
      ledgerInjectionCacheIdentity: materialized?.injectionCacheIdentity ?? '',
      ledgerProjectionFreshnessProvenCurrent: resolvedContext != null,
    );
  }

  Future<void> _ensureEffectiveCanonCurrent({
    required String charId,
    required ChatSession? session,
    required EffectiveCanonContext? context,
  }) async {
    if (session == null || context == null) return;
    final current = await _ref.read(characterRepoProvider).getById(charId);
    final isCurrent =
        current != null &&
        await _ref
            .read(effectiveCanonContextLoaderProvider)
            .isStillCurrentReadOnly(
              sessionId: session.id,
              sourceCharacter: current,
              stamp: context.stamp,
            );
    if (!isCurrent) {
      throw const PromptBuildStaleException(
        'Effective canon changed while building the prompt payload.',
      );
    }
  }
}

class _GenerationAbortedException implements Exception {
  const _GenerationAbortedException();
}
