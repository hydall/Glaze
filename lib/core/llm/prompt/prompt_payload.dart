import '../../models/character.dart';
import '../../models/persona.dart';
import '../../models/preset.dart' show Preset, PresetRegex;
import '../../models/chat_message.dart'
    show ChatMessage, AuthorsNote, TriggeredEntry;
import '../../models/api_config.dart';
import '../../models/ledger_prompt_injection_mode.dart';
import '../../models/ledger_prompt_injection_policy.dart';
import '../../models/lorebook.dart'
    show Lorebook, LorebookGlobalSettings, LorebookActivations, LorebookEntry;
import '../lorebook_scanner.dart' show ScannedEntry;
import '../memory_selector.dart' show MemorySelection;
import '../memory_excerpt_selector.dart'
    show defaultMemoryExcerptTokensPerEntry, defaultMemoryExcerptChunksPerEntry;
import 'runtime_prompt_block.dart';
import 'recalled_message_chunk.dart';
import 'effective_canon_prompt_formatter.dart';
import 'effective_canon_prompt_materializer.dart';
import 'selective_ledger_projection_filter.dart';
import '../generation_context_inputs.dart';

class PromptPayload {
  final Character character;
  final Persona? persona;
  final Preset? preset;
  final List<ChatMessage> history;
  final String? sessionId;
  final ApiConfig apiConfig;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final String? summaryContent;
  final String? summaryPrefix;
  final String? memoryContent;

  /// Raw entry text joined with \n\n — used in summary_macro mode to append
  /// directly onto the summary message (no bullet headers, no summary excerpt).
  /// Mirrors JS memoryInjection.macroContent.
  final String? memoryMacroContent;
  final String memoryInjectionTarget;
  final String? guidanceText;

  /// Continue mode: a system instruction injected immediately after the last
  /// history message (the assistant reply being extended) and before every
  /// preset block that follows `chat_history`. Null on every other path.
  /// See `docs/INVARIANTS.md` INV-CM3.
  final String? continueInstruction;
  final List<Lorebook> lorebooks;
  final LorebookGlobalSettings lorebookSettings;
  final LorebookActivations lorebookActivations;
  final List<LorebookEntry> vectorEntries;
  final AuthorsNote? authorsNote;
  final String characterDepthPrompt;
  final int characterDepthPromptDepth;
  final String characterDepthPromptRole;
  final Map<String, dynamic> memoryCoverage;
  final List<PresetRegex> globalRegexes;
  final List<ScannedEntry>? preScannedEntries;
  final List<TriggeredEntry> triggeredMemories;
  final List<RuntimePromptBlock> runtimePromptBlocks;
  final MemorySelection? memorySelection;
  final bool memoryExcerptingEnabled;
  final String memoryPackingMode;
  final int memoryExcerptTokensPerChunk;
  final int memoryExcerptChunksPerEntry;
  final int chunkFirstTopEntries;
  final int chunkFirstTopChunks;
  final String? arcContent;
  final String? entitiesContent;

  /// Compiled `<studio_session_state>` block from committed ledger tracker rows.
  /// Injected via `{{studio_state}}` macro and as a hard system block at the
  /// start of the prompt. Null/empty when Studio Ledger is disabled or no
  /// state has been committed for this session yet.
  final String? studioSessionStateContent;

  /// In-game clock from ledger `world:*` trackers for `{{gametime}}` /
  /// `{{gamedate}}` / `{{gameday}}` macros. Null when no clock is tracked.
  final String? gameTime;
  final String? gameDate;
  final String? gameDay;

  /// Scoped atomic character facts committed by Studio Ledger. This is a
  /// separate prompt layer and never mutates the base card payload.
  final String? characterKnowledgeContent;

  /// Lossless backstop
  /// chat-message chunks semantically closest to the current user message,
  /// returned by [MessageRecallService]. Injected into the prompt as a
  /// `<recalled_messages>` system block before the first user/assistant
  /// message. Rationale (patch #3): chunk=5 messages → EmbeddingRepo with
  /// `sourceType='chat_message'` → cosine ≥ 0.25, top-K=8 — lossless backstop
  /// for the lossy MemoryBook compression (Marinara memory-recall analog).
  final String? recalledMessagesContent;

  /// Structured recalled chunks with source message ids. When present, this is
  /// preferred over [recalledMessagesContent] so source-window filtering can
  /// keep raw recall out of the prompt while the source chunk is still visible.
  final List<RecalledMessageChunk> recalledMessageChunks;

  /// When true, MemoryBook entries whose source messages fall inside the
  /// visible window are NOT excluded. Studio tracker briefs are compact
  /// JSON — they never carry the source messages themselves, so
  /// deduplicating MemoryBook entries against visible messages wastes
  /// memory context that the tracker would otherwise leverage. Default
  /// false = legacy source-window exclusion applies.
  final bool disableSourceWindowExclusion;

  /// Overrides the message ids treated as visible for message-bound memory
  /// source-window exclusion. Empty means use the final token-cutoff window.
  /// Studio uses this to align memory injection with the final generator's
  /// `maxFinalHistoryMessages` window, which is applied after base prompt build.
  final Set<String> sourceWindowVisibleMessageIds;

  /// djb2-style hash of the compiled memory injection content for this
  /// turn. Used by the next generation to detect "memory changed since
  /// last turn" and invalidate prompt cache (Anthropic / DeepSeek prompt
  /// caching). When this fingerprint matches the previous turn's, the
  /// prompt cache is valid; when it differs, the cache misses — but
  /// correctness is unaffected (the new memory content is sent). Mirrors
  /// Marinara's `chatSummaryFingerprint` (djb2 on compiled summary). We
  /// hash the MemoryBook injection content (MemoryBook is our summary
  /// equivalent). Empty when no memory content was injected.
  /// Rationale: Glaze has no separate Chat Summary system — MemoryBook
  /// IS our summary (chronologically ordered entries with messageIds linkage).
  /// The fingerprint detects "memory changed since last turn" for prompt-cache
  /// invalidation (Marinara chatSummaryFingerprint / djb2 analog).
  final String memoryInjectionFingerprint;
  final EffectiveCanonPromptProjection? effectiveCanonProjection;
  final int? effectiveCanonRevisionNumber;
  final String? effectiveCanonRevisionHash;
  final String effectiveCanonCacheIdentity;
  final LedgerPromptInjectionPolicy ledgerPromptInjectionPolicy;
  final String ledgerInjectionCacheIdentity;
  final bool ledgerProjectionFreshnessProvenCurrent;

  const PromptPayload({
    required this.character,
    this.persona,
    this.preset,
    required this.history,
    this.sessionId,
    required this.apiConfig,
    this.sessionVars = const {},
    this.globalVars = const {},
    this.summaryContent,
    this.summaryPrefix,
    this.memoryContent,
    this.memoryMacroContent,
    this.memoryInjectionTarget = 'summary_block',
    this.guidanceText,
    this.continueInstruction,
    this.lorebooks = const [],
    this.lorebookSettings = const LorebookGlobalSettings(),
    this.lorebookActivations = const LorebookActivations(),
    this.vectorEntries = const [],
    this.authorsNote,
    this.characterDepthPrompt = '',
    this.characterDepthPromptDepth = 4,
    this.characterDepthPromptRole = 'system',
    this.memoryCoverage = const {},
    this.globalRegexes = const [],
    this.preScannedEntries,
    this.triggeredMemories = const [],
    this.runtimePromptBlocks = const [],
    this.memorySelection,
    this.memoryExcerptingEnabled = true,
    this.memoryPackingMode = 'hybrid',
    this.memoryExcerptTokensPerChunk = defaultMemoryExcerptTokensPerEntry,
    this.memoryExcerptChunksPerEntry = defaultMemoryExcerptChunksPerEntry,
    this.chunkFirstTopEntries = 3,
    this.chunkFirstTopChunks = 1,
    this.arcContent,
    this.entitiesContent,
    this.studioSessionStateContent,
    this.gameTime,
    this.gameDate,
    this.gameDay,
    this.characterKnowledgeContent,
    this.recalledMessagesContent,
    this.recalledMessageChunks = const [],
    this.disableSourceWindowExclusion = false,
    this.sourceWindowVisibleMessageIds = const {},
    this.memoryInjectionFingerprint = '',
    this.effectiveCanonProjection,
    this.effectiveCanonRevisionNumber,
    this.effectiveCanonRevisionHash,
    this.effectiveCanonCacheIdentity = '',
    this.ledgerPromptInjectionPolicy = const LedgerPromptInjectionPolicy(
      presetOptIn: true,
      mode: LedgerPromptInjectionMode.legacy,
    ),
    this.ledgerInjectionCacheIdentity = '',
    this.ledgerProjectionFreshnessProvenCurrent = false,
  });

  factory PromptPayload.fromGenerationContext(
    GenerationContextInputs inputs, {
    required Preset? preset,
    bool disableSourceWindowExclusion = false,
    Set<String> sourceWindowVisibleMessageIds = const {},
    LedgerPromptInjectionPolicy? ledgerPromptInjectionPolicy,
    String consumerPath = 'ordinary',
  }) {
    final projection = inputs.effectiveCanonProjection;
    final policy =
        ledgerPromptInjectionPolicy ?? inputs.ledgerPromptInjectionPolicy;
    // Do not run history-dependent Ledger selection here. This factory is also
    // used by prefetched/raw-input paths, where [inputs.history] is not yet the
    // token-trimmed responder context. buildPrompt owns the frozen-baseline
    // materialization boundary.
    final materialized = projection == null
        ? null
        : EffectiveCanonPromptMaterializer.materializeSafely(
            SelectiveLedgerProjectionInput(
              policy: LedgerPromptInjectionPolicy(
                presetOptIn: policy.presetOptIn,
                mode: policy.effectiveMode == LedgerPromptInjectionMode.disabled
                    ? LedgerPromptInjectionMode.disabled
                    : LedgerPromptInjectionMode.legacy,
                algorithmVersion: policy.algorithmVersion,
                reverseScanDepth: policy.reverseScanDepth,
              ),
              consumerPath: consumerPath,
              projection: projection,
              visibleMessages: const [],
              selectedSwipeByMessageId: const {},
              focalUserName: inputs.persona?.name ?? '',
              structuredContinuitySourceIds: const {},
            ),
            sessionId: inputs.sessionId ?? '',
            latestUserText: _latestText(inputs.history, 'user'),
            latestAssistantText: _latestText(inputs.history, 'assistant'),
          );
    final disabled = policy.effectiveMode == LedgerPromptInjectionMode.disabled;
    return PromptPayload(
      character: inputs.character,
      persona: inputs.persona,
      preset: preset,
      history: inputs.history,
      sessionId: inputs.sessionId,
      apiConfig: inputs.apiConfig,
      sessionVars: inputs.sessionVars,
      globalVars: inputs.globalVars,
      summaryContent: inputs.summaryContent,
      summaryPrefix: inputs.summaryPrefix,
      memoryContent: inputs.memoryContent,
      memoryMacroContent: inputs.memoryMacroContent,
      memoryInjectionTarget: inputs.memoryInjectionTarget,
      guidanceText: inputs.guidanceText,
      continueInstruction: inputs.continueInstruction,
      lorebooks: inputs.lorebooks,
      lorebookSettings: inputs.lorebookSettings,
      lorebookActivations: inputs.lorebookActivations,
      vectorEntries: inputs.vectorEntries,
      authorsNote: inputs.authorsNote,
      characterDepthPrompt: inputs.characterDepthPrompt,
      characterDepthPromptDepth: inputs.characterDepthPromptDepth,
      characterDepthPromptRole: inputs.characterDepthPromptRole,
      memoryCoverage: inputs.memoryCoverage,
      globalRegexes: inputs.globalRegexes,
      preScannedEntries: inputs.preScannedEntries,
      triggeredMemories: inputs.triggeredMemories,
      runtimePromptBlocks: inputs.runtimePromptBlocks,
      memorySelection: inputs.memorySelection,
      memoryExcerptingEnabled: inputs.memoryExcerptingEnabled,
      memoryPackingMode: inputs.memoryPackingMode,
      memoryExcerptTokensPerChunk: inputs.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: inputs.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: inputs.chunkFirstTopEntries,
      chunkFirstTopChunks: inputs.chunkFirstTopChunks,
      arcContent: materialized != null
          ? materialized.arcContent
          : (disabled ? null : inputs.arcContent),
      entitiesContent: inputs.entitiesContent,
      studioSessionStateContent: materialized != null
          ? materialized.studioSessionStateContent
          : (disabled ? null : inputs.studioSessionStateContent),
      gameTime: inputs.gameTime,
      gameDate: inputs.gameDate,
      gameDay: inputs.gameDay,
      characterKnowledgeContent: materialized != null
          ? materialized.characterKnowledgeContent
          : (disabled ? null : inputs.characterKnowledgeContent),
      recalledMessagesContent: inputs.recalledMessagesContent,
      recalledMessageChunks: inputs.recalledMessageChunks,
      disableSourceWindowExclusion: disableSourceWindowExclusion,
      sourceWindowVisibleMessageIds: sourceWindowVisibleMessageIds,
      memoryInjectionFingerprint: inputs.memoryInjectionFingerprint,
      effectiveCanonProjection: inputs.effectiveCanonProjection,
      effectiveCanonRevisionNumber: inputs.effectiveCanonRevisionNumber,
      effectiveCanonRevisionHash: inputs.effectiveCanonRevisionHash,
      effectiveCanonCacheIdentity: inputs.effectiveCanonCacheIdentity,
      ledgerPromptInjectionPolicy: policy,
      ledgerInjectionCacheIdentity:
          materialized?.injectionCacheIdentity ??
          inputs.ledgerInjectionCacheIdentity,
      ledgerProjectionFreshnessProvenCurrent:
          inputs.ledgerProjectionFreshnessProvenCurrent,
    );
  }

  PromptPayload withLedgerMaterialization(
    EffectiveCanonPromptMaterialization materialization,
  ) => PromptPayload(
    character: character,
    persona: persona,
    preset: preset,
    history: history,
    sessionId: sessionId,
    apiConfig: apiConfig,
    sessionVars: sessionVars,
    globalVars: globalVars,
    summaryContent: summaryContent,
    summaryPrefix: summaryPrefix,
    memoryContent: memoryContent,
    memoryMacroContent: memoryMacroContent,
    memoryInjectionTarget: memoryInjectionTarget,
    guidanceText: guidanceText,
    continueInstruction: continueInstruction,
    lorebooks: lorebooks,
    lorebookSettings: lorebookSettings,
    lorebookActivations: lorebookActivations,
    vectorEntries: vectorEntries,
    authorsNote: authorsNote,
    characterDepthPrompt: characterDepthPrompt,
    characterDepthPromptDepth: characterDepthPromptDepth,
    characterDepthPromptRole: characterDepthPromptRole,
    memoryCoverage: memoryCoverage,
    globalRegexes: globalRegexes,
    preScannedEntries: preScannedEntries,
    triggeredMemories: triggeredMemories,
    runtimePromptBlocks: runtimePromptBlocks,
    memorySelection: memorySelection,
    memoryExcerptingEnabled: memoryExcerptingEnabled,
    memoryPackingMode: memoryPackingMode,
    memoryExcerptTokensPerChunk: memoryExcerptTokensPerChunk,
    memoryExcerptChunksPerEntry: memoryExcerptChunksPerEntry,
    chunkFirstTopEntries: chunkFirstTopEntries,
    chunkFirstTopChunks: chunkFirstTopChunks,
    arcContent: materialization.arcContent,
    entitiesContent: entitiesContent,
    studioSessionStateContent: materialization.studioSessionStateContent,
    gameTime: gameTime,
    gameDate: gameDate,
    gameDay: gameDay,
    characterKnowledgeContent: materialization.characterKnowledgeContent,
    recalledMessagesContent: recalledMessagesContent,
    recalledMessageChunks: recalledMessageChunks,
    disableSourceWindowExclusion: disableSourceWindowExclusion,
    sourceWindowVisibleMessageIds: sourceWindowVisibleMessageIds,
    memoryInjectionFingerprint: memoryInjectionFingerprint,
    effectiveCanonProjection: effectiveCanonProjection,
    effectiveCanonRevisionNumber: effectiveCanonRevisionNumber,
    effectiveCanonRevisionHash: effectiveCanonRevisionHash,
    effectiveCanonCacheIdentity: effectiveCanonCacheIdentity,
    ledgerPromptInjectionPolicy: ledgerPromptInjectionPolicy,
    ledgerInjectionCacheIdentity: materialization.injectionCacheIdentity,
    ledgerProjectionFreshnessProvenCurrent:
        ledgerProjectionFreshnessProvenCurrent,
  );
}

String _latestText(List<ChatMessage> history, String role) => history
    .lastWhere(
      (message) => message.role == role,
      orElse: () => const ChatMessage(id: '', role: '', content: ''),
    )
    .content;
