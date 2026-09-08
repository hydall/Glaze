import '../../../core/models/memory_book.dart';
import '../../../core/state/memory_settings_provider.dart';

/// Pure bidirectional mapper between the global [MemoryGlobalSettings]
/// (singleton, SharedPreferences-backed) and the per-session
/// [MemoryBookSettings] snapshot stored inside a [MemoryBook].
///
/// Extracted from [MemoryBookController] (plan §6) to keep the read/write
/// mapping in one testable place. The mapper is pure: it does not touch `Ref`
/// and only converts between the two settings shapes. The host controller
/// still owns the persistence side effects (saving the global settings +
/// updating the book's settings).
class MemorySettingsMapper {
  const MemorySettingsMapper();

  /// Project the global settings into the per-session book-settings snapshot.
  MemoryBookSettings globalToBook(MemoryGlobalSettings g) {
    return MemoryBookSettings(
      enabled: g.enabled,
      memoryMode: g.memoryMode,
      autoCreateEnabled: g.autoCreateEnabled,
      autoGenerateEnabled: g.autoGenerateEnabled,
      maxInjectedEntries: g.maxInjectedEntries,
      memoryExcerptingEnabled: g.memoryExcerptingEnabled,
      memoryPackingMode: g.memoryPackingMode,
      memoryExcerptTokensPerChunk: g.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: g.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: g.chunkFirstTopEntries,
      chunkFirstTopChunks: g.chunkFirstTopChunks,
      maxInjectedTokens: g.maxInjectedTokens,
      memoryBudgetPreset: g.memoryBudgetPreset,
      autoCreateInterval: g.autoCreateInterval,
      autoCreateLagMessages: g.autoCreateLagMessages,
      useDelayedAutomation: g.useDelayedAutomation,
      injectionTarget: g.injectionTarget,
      batchSize: g.batchSize,
      vectorSearchEnabled: g.vectorSearchEnabled,
      keyMatchMode: g.keyMatchMode,
      promptPreset: g.promptPreset,
      diversityAware: g.diversityAware,
      diversityPenalty: g.diversityPenalty,
      recencyBoost: g.recencyBoost,
      recencyHalfLifeDays: g.recencyHalfLifeDays,
      importanceBoost: g.importanceBoost,
      importanceWeight: g.importanceWeight,
      sourceWindowExclusion: g.sourceWindowExclusion,
      factualContinuityGuardEnabled: g.factualContinuityGuardEnabled,
      queryIncludeAssistant: g.queryIncludeAssistant,
      queryRecentTurns: g.queryRecentTurns,
      queryMaxChars: g.queryMaxChars,
    );
  }

  /// Reverse the per-session book-settings snapshot back into a global
  /// settings instance. Fields not present on [MemoryBookSettings] are
  /// carried over from [currentGlobal]:
  /// - `parallelJobs`, `vectorThreshold` (overridden by [vectorThreshold]
  ///   arg), `customPrompts`, `cadence*`, `consolidation*`.
  MemoryGlobalSettings bookToGlobal(
    MemoryBookSettings newSettings,
    MemoryGlobalSettings currentGlobal,
    double vectorThreshold,
  ) {
    return MemoryGlobalSettings(
      enabled: newSettings.enabled,
      memoryMode: newSettings.memoryMode,
      autoCreateEnabled: newSettings.autoCreateEnabled,
      autoGenerateEnabled: newSettings.autoGenerateEnabled,
      maxInjectedEntries: newSettings.maxInjectedEntries,
      memoryExcerptingEnabled: newSettings.memoryExcerptingEnabled,
      memoryPackingMode: newSettings.memoryPackingMode,
      memoryExcerptTokensPerChunk: newSettings.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: newSettings.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: newSettings.chunkFirstTopEntries,
      chunkFirstTopChunks: newSettings.chunkFirstTopChunks,
      maxInjectedTokens: newSettings.maxInjectedTokens,
      memoryBudgetPreset: newSettings.memoryBudgetPreset,
      autoCreateInterval: newSettings.autoCreateInterval,
      autoCreateLagMessages: newSettings.autoCreateLagMessages,
      useDelayedAutomation: newSettings.useDelayedAutomation,
      injectionTarget: newSettings.injectionTarget,
      batchSize: newSettings.batchSize,
      parallelJobs: currentGlobal.parallelJobs,
      vectorSearchEnabled: newSettings.vectorSearchEnabled,
      vectorThreshold: vectorThreshold,
      keyMatchMode: newSettings.keyMatchMode,
      promptPreset: newSettings.promptPreset,
      diversityAware: newSettings.diversityAware,
      diversityPenalty: newSettings.diversityPenalty,
      recencyBoost: newSettings.recencyBoost,
      recencyHalfLifeDays: newSettings.recencyHalfLifeDays,
      importanceBoost: newSettings.importanceBoost,
      importanceWeight: newSettings.importanceWeight,
      sourceWindowExclusion: newSettings.sourceWindowExclusion,
      factualContinuityGuardEnabled: newSettings.factualContinuityGuardEnabled,
      queryIncludeAssistant: newSettings.queryIncludeAssistant,
      queryRecentTurns: newSettings.queryRecentTurns,
      queryMaxChars: newSettings.queryMaxChars,
      cadenceInterval: newSettings.cadenceInterval,
      consolidationEnabled: newSettings.consolidationEnabled,
      consolidationThreshold: newSettings.consolidationThreshold,
      customPrompts: currentGlobal.customPrompts,
    );
  }
}
