import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../state/active_selection_provider.dart';
import '../state/db_provider.dart';
import '../state/global_regex_provider.dart';
import '../state/lorebook_provider.dart';
import '../state/memory_settings_provider.dart';
import '../state/summary_providers.dart';
import 'prompt_builder.dart';
import 'prompt_inputs.dart';
import '../models/ledger_prompt_injection_policy.dart';

typedef ApiConfigInitializer = Future<void> Function();
typedef ActiveApiConfigReader = ApiConfig? Function();
typedef PromptHistoryInjector =
    Future<List<ChatMessage>> Function({
      required String sessionId,
      required List<ChatMessage> messages,
    });
typedef RuntimePromptBlocksReader =
    List<RuntimePromptBlock> Function(String sessionId);

class PromptInputsCollector {
  final Ref _ref;
  final ApiConfigInitializer _initializeApiConfigs;
  final ActiveApiConfigReader _readActiveApiConfig;
  final PromptHistoryInjector _injectHistory;
  final RuntimePromptBlocksReader _readRuntimePromptBlocks;

  factory PromptInputsCollector(
    Ref ref, {
    required ApiConfigInitializer initializeApiConfigs,
    required ActiveApiConfigReader readActiveApiConfig,
    required PromptHistoryInjector injectHistory,
    required RuntimePromptBlocksReader readRuntimePromptBlocks,
  }) => PromptInputsCollector._(
    ref,
    initializeApiConfigs,
    readActiveApiConfig,
    injectHistory,
    readRuntimePromptBlocks,
  );

  PromptInputsCollector._(
    this._ref,
    this._initializeApiConfigs,
    this._readActiveApiConfig,
    this._injectHistory,
    this._readRuntimePromptBlocks,
  );

  /// Collects raw inputs from DB/providers for isolate-based processing.
  /// Fast path: DB reads only, no memory injection or vector search.
  Future<PromptInputs> collectInputs({
    required String charId,
    required ChatSession? session,
    String? guidanceText,
  }) async {
    final charRepo = _ref.read(characterRepoProvider);
    final presetRepo = _ref.read(presetRepoProvider);
    final personaRepo = _ref.read(personaRepoProvider);
    final lorebookRepo = _ref.read(lorebookRepoProvider);

    final sourceCharacter = await charRepo.getById(charId);
    if (sourceCharacter == null) {
      throw StateError('Character not found: $charId');
    }
    final character = sourceCharacter;

    await _initializeApiConfigs();
    final chatApi = _readActiveApiConfig();
    if (chatApi == null || chatApi.mode == 'embedding') {
      throw StateError('No chat API config available');
    }

    final activePresetId = _ref.read(activePresetIdProvider);
    final presetConnections = _ref.read(presetConnectionsProvider);
    final presets = await presetRepo.getAll();
    final preset = getEffectivePreset(
      presets,
      charId,
      session?.id,
      activePresetId,
      presetConnections,
    );

    final personas = await personaRepo.getAll();
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

    final sourceLorebooks = await lorebookRepo.getAll();
    final lorebooks = session == null
        ? sourceLorebooks
        : await _ref
              .read(sessionLorebookEvolutionRepoProvider)
              .applyOverlays(sessionId: session.id, lorebooks: sourceLorebooks);
    final lorebookSettings = _ref.read(lorebookSettingsProvider);
    final lorebookActivations = _ref.read(lorebookActivationsProvider);

    String? summaryContent;
    if (session != null) {
      final summaryService = _ref.read(summaryServiceProvider);
      summaryContent = await summaryService.getSummary(session.id);
    }

    final memoryBook = session != null
        ? await _ref.read(memoryBookRepoProvider).getBySessionId(session.id)
        : null;
    final memoryEntries = memoryBook?.entries ?? [];

    final memorySettings = _ref.read(memoryGlobalSettingsProvider);

    var history = session?.messages ?? [];
    var runtimePromptBlocks = const <RuntimePromptBlock>[];
    if (session != null) {
      history = await _injectHistory(sessionId: session.id, messages: history);
      runtimePromptBlocks = _readRuntimePromptBlocks(session.id);
    }

    return PromptInputs(
      character: character,
      persona: persona,
      preset: preset,
      history: history,
      apiConfig: chatApi,
      sessionVars: session?.sessionVars ?? {},
      globalVars: _ref.read(globalVarsProvider),
      lorebooks: lorebooks,
      lorebookSettings: lorebookSettings,
      lorebookActivations: lorebookActivations,
      summaryContent: summaryContent,
      guidanceText: guidanceText,
      authorsNote: session?.authorsNote,
      characterDepthPrompt: character.depthPrompt,
      characterDepthPromptDepth: character.depthPromptDepth,
      characterDepthPromptRole: character.depthPromptRole,
      globalRegexes: _ref.read(globalRegexProvider).value ?? [],
      memoryEntries: memoryEntries,
      memoryEnabled: memorySettings.enabled,
      memoryMode: memorySettings.memoryMode,
      memoryMaxInjected: memorySettings.maxInjectedEntries,
      memoryExcerptingEnabled:
          memoryBook?.settings.memoryExcerptingEnabled ??
          memorySettings.memoryExcerptingEnabled,
      memoryPackingMode:
          memoryBook?.settings.memoryPackingMode ??
          memorySettings.memoryPackingMode,
      memoryExcerptTokensPerChunk:
          memoryBook?.settings.memoryExcerptTokensPerChunk ??
          memorySettings.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry:
          memoryBook?.settings.memoryExcerptChunksPerEntry ??
          memorySettings.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries:
          memoryBook?.settings.chunkFirstTopEntries ??
          memorySettings.chunkFirstTopEntries,
      chunkFirstTopChunks:
          memoryBook?.settings.chunkFirstTopChunks ??
          memorySettings.chunkFirstTopChunks,
      memoryKeyMatchMode: memorySettings.keyMatchMode,
      memoryInjectionTarget: memorySettings.injectionTarget,
      memoryMaxInjectedTokens: memoryBook?.settings.maxInjectedTokens,
      memoryMaxInjectionBudgetPercent:
          memoryBook?.settings.maxInjectionBudgetPercent ?? 0.35,
      memoryDiversityAware: memoryBook?.settings.diversityAware ?? true,
      memoryDiversityPenalty: memoryBook?.settings.diversityPenalty ?? 0.15,
      memoryRecencyBoost: memoryBook?.settings.recencyBoost ?? true,
      memoryRecencyHalfLifeDays:
          memoryBook?.settings.recencyHalfLifeDays ?? 100,
      memoryImportanceBoost: memoryBook?.settings.importanceBoost ?? true,
      memoryImportanceWeight: memoryBook?.settings.importanceWeight ?? 0.5,
      memorySourceWindowExclusion:
          memoryBook?.settings.sourceWindowExclusion ?? true,
      memoryQueryIncludeAssistant:
          memoryBook?.settings.queryIncludeAssistant ?? true,
      memoryQueryRecentTurns: memoryBook?.settings.queryRecentTurns ?? 6,
      memoryQueryMaxChars: memoryBook?.settings.queryMaxChars ?? 1500,
      memoryContextBudgetTokens: chatApi.contextSize,
      runtimePromptBlocks: runtimePromptBlocks,
      effectiveCanonProjection: null,
      ledgerPromptInjectionPolicy: disabledLedgerPromptInjectionPolicy,
      // The read-only stamp comparison above proves that this projection did
      // not change while its history snapshot was collected. buildPrompt will
      // still suppress only against messages that survive final token trim.
      ledgerProjectionFreshnessProvenCurrent: false,
    );
  }
}
