import 'package:flutter/material.dart';

import '../../../../../core/models/memory_book.dart';

/// The in-progress edit of [MemoryBookSettings] behind the settings sheet.
///
/// The sheet used to hold thirty-odd `late` fields directly on its `State`,
/// which is what made it a single 1223-line class: every tab, every row and
/// every normalizer had to live next to them. The edit is a value now, so each
/// section of the form is its own widget and the sheet is just the host that
/// owns this object and decides when it is saved.
///
/// Mutable on purpose — it is a form buffer, not domain state. Nothing reads
/// it outside the sheet, and nothing is persisted until [toSettings] is handed
/// back on save.
class MemorySettingsDraft {
  bool enabled;
  String memoryMode;
  bool autoCreate;
  bool autoGenerate;
  bool useDelayedAutomation;
  int autoCreateInterval;
  int autoCreateLagMessages;
  int batchSize;
  String promptPreset;

  int maxInjected;
  String memoryBudgetPreset;
  int? maxInjectedTokens;
  bool memoryExcerptingEnabled;
  String memoryPackingMode;
  int memoryExcerptTokensPerChunk;
  int memoryExcerptChunksPerEntry;
  int chunkFirstTopEntries;
  int chunkFirstTopChunks;
  bool diversityAware;
  double diversityPenalty;
  bool recencyBoost;
  double recencyHalfLifeDays;
  bool importanceBoost;
  double importanceWeight;
  bool sourceWindowExclusion;
  bool factualContinuityGuardEnabled;
  bool queryIncludeAssistant;
  int queryRecentTurns;
  int queryMaxChars;

  String injectionTarget;
  String keyMatchMode;
  bool vectorSearchEnabled;
  double vectorThreshold;

  /// The custom token budget field. Lives here rather than in a tab so the
  /// value survives a tab switch, which rebuilds the tab bodies.
  final TextEditingController budgetController;

  MemorySettingsDraft._({
    required this.enabled,
    required this.memoryMode,
    required this.autoCreate,
    required this.autoGenerate,
    required this.useDelayedAutomation,
    required this.autoCreateInterval,
    required this.autoCreateLagMessages,
    required this.batchSize,
    required this.promptPreset,
    required this.maxInjected,
    required this.memoryBudgetPreset,
    required this.maxInjectedTokens,
    required this.memoryExcerptingEnabled,
    required this.memoryPackingMode,
    required this.memoryExcerptTokensPerChunk,
    required this.memoryExcerptChunksPerEntry,
    required this.chunkFirstTopEntries,
    required this.chunkFirstTopChunks,
    required this.diversityAware,
    required this.diversityPenalty,
    required this.recencyBoost,
    required this.recencyHalfLifeDays,
    required this.importanceBoost,
    required this.importanceWeight,
    required this.sourceWindowExclusion,
    required this.factualContinuityGuardEnabled,
    required this.queryIncludeAssistant,
    required this.queryRecentTurns,
    required this.queryMaxChars,
    required this.injectionTarget,
    required this.keyMatchMode,
    required this.vectorSearchEnabled,
    required this.vectorThreshold,
    required this.budgetController,
  });

  factory MemorySettingsDraft.from(
    MemoryBookSettings s, {
    required double vectorThreshold,
  }) {
    final budgetPreset = normalizeBudgetPreset(
      s.memoryBudgetPreset,
      s.maxInjectedTokens,
    );
    final budgetTokens = budgetTokensForPreset(
      budgetPreset,
      s.maxInjectedTokens,
    );
    return MemorySettingsDraft._(
      enabled: s.enabled,
      memoryMode: normalizeMemoryMode(s.memoryMode),
      autoCreate: s.autoCreateEnabled,
      autoGenerate: s.autoGenerateEnabled,
      useDelayedAutomation: s.useDelayedAutomation,
      autoCreateInterval: s.autoCreateInterval,
      autoCreateLagMessages: s.autoCreateLagMessages,
      batchSize: s.batchSize,
      // Keep the persisted per-book key intact. Global settings may still be
      // loading; resolution helpers provide a safe display/runtime fallback.
      promptPreset: s.promptPreset,
      maxInjected: s.maxInjectedEntries,
      memoryBudgetPreset: budgetPreset,
      maxInjectedTokens: budgetTokens,
      memoryExcerptingEnabled: s.memoryExcerptingEnabled,
      memoryPackingMode: normalizePackingMode(s.memoryPackingMode),
      memoryExcerptTokensPerChunk: s.memoryExcerptTokensPerChunk.clamp(
        100,
        2000,
      ),
      memoryExcerptChunksPerEntry: s.memoryExcerptChunksPerEntry.clamp(1, 10),
      chunkFirstTopEntries: s.chunkFirstTopEntries.clamp(0, 20),
      chunkFirstTopChunks:
          (s.chunkFirstTopChunks <= 0 ? 1 : s.chunkFirstTopChunks).clamp(1, 10),
      diversityAware: s.diversityAware,
      diversityPenalty: s.diversityPenalty,
      recencyBoost: s.recencyBoost,
      recencyHalfLifeDays: s.recencyHalfLifeDays,
      importanceBoost: s.importanceBoost,
      importanceWeight: s.importanceWeight,
      sourceWindowExclusion: s.sourceWindowExclusion,
      factualContinuityGuardEnabled: s.factualContinuityGuardEnabled,
      queryIncludeAssistant: s.queryIncludeAssistant,
      queryRecentTurns: s.queryRecentTurns,
      queryMaxChars: s.queryMaxChars,
      injectionTarget: migrateInjectionTarget(s.injectionTarget),
      keyMatchMode: s.keyMatchMode,
      vectorSearchEnabled: s.vectorSearchEnabled,
      vectorThreshold: vectorThreshold,
      budgetController: TextEditingController(
        text: (budgetTokens ?? 6000).toString(),
      ),
    );
  }

  void dispose() => budgetController.dispose();

  /// Applies the budget preset, keeping the custom field in step so switching
  /// away and back does not lose the typed number.
  void setBudgetPreset(String preset) {
    memoryBudgetPreset = preset;
    maxInjectedTokens = budgetTokensForPreset(preset, maxInjectedTokens);
    if (maxInjectedTokens != null) {
      budgetController.text = maxInjectedTokens.toString();
    }
  }

  MemoryBookSettings toSettings(MemoryBookSettings base) => base.copyWith(
    enabled: enabled,
    memoryMode: memoryMode,
    autoCreateEnabled: autoCreate,
    autoGenerateEnabled: autoGenerate,
    maxInjectedEntries: maxInjected,
    memoryExcerptingEnabled: memoryExcerptingEnabled,
    memoryPackingMode: memoryPackingMode,
    memoryExcerptTokensPerChunk: memoryExcerptTokensPerChunk,
    memoryExcerptChunksPerEntry: memoryExcerptChunksPerEntry,
    chunkFirstTopEntries: chunkFirstTopEntries,
    chunkFirstTopChunks: chunkFirstTopChunks,
    maxInjectedTokens: maxInjectedTokens,
    memoryBudgetPreset: memoryBudgetPreset,
    autoCreateInterval: autoCreateInterval,
    autoCreateLagMessages: autoCreateLagMessages,
    batchSize: batchSize,
    useDelayedAutomation: useDelayedAutomation,
    injectionTarget: injectionTarget,
    promptPreset: promptPreset,
    keyMatchMode: keyMatchMode,
    vectorSearchEnabled: vectorSearchEnabled,
    diversityAware: diversityAware,
    diversityPenalty: diversityPenalty,
    recencyBoost: recencyBoost,
    recencyHalfLifeDays: recencyHalfLifeDays,
    importanceBoost: importanceBoost,
    importanceWeight: importanceWeight,
    sourceWindowExclusion: sourceWindowExclusion,
    factualContinuityGuardEnabled: factualContinuityGuardEnabled,
    queryIncludeAssistant: queryIncludeAssistant,
    queryRecentTurns: queryRecentTurns,
    queryMaxChars: queryMaxChars,
  );
}

/// Translates the legacy `summary_block` / `summary_macro` enum values
/// (pre-{{memory}}-split) to `hard_block` / `macro`. Defence in depth — the
/// underlying model also migrates in its `fromJson`.
String migrateInjectionTarget(String raw) {
  if (raw == 'summary_block') return 'hard_block';
  if (raw == 'summary_macro') return 'macro';
  return raw;
}

String normalizeMemoryMode(String raw) {
  if (raw == 'legacy') return 'legacy';
  // Deep is hidden while it is being completed. The intended mode uses a
  // separate LLM call to select relevant memories and to propose consolidated
  // or updated entries. Keep accepting persisted `deep`/`agentic` values for
  // compatibility until that reviewed update workflow is implemented.
  if (raw == 'deep' || raw == 'agentic') return 'balanced';
  return raw == 'balanced' ? 'balanced' : 'fast';
}

String normalizePackingMode(String raw) {
  if (raw == 'full' || raw == 'chunk_first') return raw;
  return 'hybrid';
}

String normalizeBudgetPreset(String preset, int? tokens) {
  if (preset == 'small' ||
      preset == 'medium' ||
      preset == 'large' ||
      preset == 'custom') {
    return preset;
  }
  return tokens == null ? 'auto' : 'custom';
}

int? budgetTokensForPreset(String preset, int? currentCustom) {
  switch (preset) {
    case 'auto':
      return null;
    case 'small':
      return 3000;
    case 'medium':
      return 6000;
    case 'large':
      return 10000;
    case 'custom':
      return currentCustom ?? 6000;
    default:
      return null;
  }
}
