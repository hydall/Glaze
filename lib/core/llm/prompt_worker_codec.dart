import '../models/character.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import '../models/chat_message.dart';
import '../models/api_config.dart';
import '../models/lorebook.dart';
import '../models/memory_book.dart';
import 'context_calculator.dart';
import 'history_assembler.dart';
import 'lorebook_scanner.dart';
import 'memory_excerpt_selector.dart';
import 'memory_selector.dart';
import 'prompt_builder.dart';

/// Serialization codec for the prompt isolate boundary. Converts
/// [PromptPayload] / [PromptResult] / [MemorySelection] to and from plain JSON
/// maps so they can cross the isolate port.
Map<String, dynamic> serializePayload(PromptPayload p) => {
  'character': p.character.toJson(),
  'persona': p.persona?.toJson(),
  'preset': p.preset?.toJson(),
  'history': p.history.map((m) => m.toJson()).toList(),
  'sessionId': p.sessionId,
  'apiConfig': p.apiConfig.toJson(),
  'sessionVars': p.sessionVars,
  'globalVars': p.globalVars,
  'summaryContent': p.summaryContent,
  'summaryPrefix': p.summaryPrefix,
  'memoryContent': p.memoryContent,
  'memoryMacroContent': p.memoryMacroContent,
  'memoryInjectionTarget': p.memoryInjectionTarget,
  'guidanceText': p.guidanceText,
  'lorebooks': p.lorebooks.map((l) => l.toJson()).toList(),
  'lorebookSettings': p.lorebookSettings.toJson(),
  'lorebookActivations': p.lorebookActivations.toJson(),
  'vectorEntries': p.vectorEntries.map((e) => e.toJson()).toList(),
  'authorsNote': p.authorsNote?.toJson(),
  'characterDepthPrompt': p.characterDepthPrompt,
  'characterDepthPromptDepth': p.characterDepthPromptDepth,
  'characterDepthPromptRole': p.characterDepthPromptRole,
  'memoryCoverage': p.memoryCoverage,
  'globalRegexes': p.globalRegexes.map((r) => r.toJson()).toList(),
  'preScannedEntries': p.preScannedEntries?.map((e) => e.toJson()).toList(),
  'triggeredMemories': p.triggeredMemories.map((t) => t.toJson()).toList(),
  'runtimePromptBlocks': p.runtimePromptBlocks
      .map((block) => block.toJson())
      .toList(),
  'memorySelection': serializeMemorySelection(p.memorySelection),
  'memoryExcerptingEnabled': p.memoryExcerptingEnabled,
  'memoryPackingMode': p.memoryPackingMode,
  'memoryExcerptTokensPerChunk': p.memoryExcerptTokensPerChunk,
  'memoryExcerptChunksPerEntry': p.memoryExcerptChunksPerEntry,
  'chunkFirstTopEntries': p.chunkFirstTopEntries,
  'chunkFirstTopChunks': p.chunkFirstTopChunks,
  'arcContent': p.arcContent,
  'entitiesContent': p.entitiesContent,
  'studioSessionStateContent': p.studioSessionStateContent,
  'characterKnowledgeContent': p.characterKnowledgeContent,
  'recalledMessagesContent': p.recalledMessagesContent,
  'recalledMessageChunks': p.recalledMessageChunks
      .map((c) => c.toJson())
      .toList(),
  'disableSourceWindowExclusion': p.disableSourceWindowExclusion,
  'sourceWindowVisibleMessageIds': p.sourceWindowVisibleMessageIds.toList(),
  'memoryInjectionFingerprint': p.memoryInjectionFingerprint,
};

PromptResult deserializeResult(Map<String, dynamic> json) {
  return PromptResult(
    messages: (json['messages'] as List)
        .map((m) => PromptMessage.fromJson(m as Map<String, dynamic>))
        .toList(),
    breakdown: TokenBreakdown.fromJson(
      json['breakdown'] as Map<String, dynamic>,
    ),
    sessionVars: Map<String, String>.from(json['sessionVars'] as Map),
    globalVars: Map<String, String>.from(json['globalVars'] as Map),
    triggeredLorebooks: (json['triggeredLorebooks'] as List? ?? [])
        .map((t) => TriggeredEntry.fromJson(t as Map<String, dynamic>))
        .toList(),
    triggeredMemories: (json['triggeredMemories'] as List? ?? [])
        .map((t) => TriggeredEntry.fromJson(t as Map<String, dynamic>))
        .toList(),
    memoryCoverage: Map<String, dynamic>.from(
      json['memoryCoverage'] as Map? ?? {},
    ),
  );
}

PromptPayload deserializePayload(Map<String, dynamic> json) {
  return PromptPayload(
    character: Character.fromJson(json['character'] as Map<String, dynamic>),
    persona: json['persona'] != null
        ? Persona.fromJson(json['persona'] as Map<String, dynamic>)
        : null,
    preset: json['preset'] != null
        ? Preset.fromJson(json['preset'] as Map<String, dynamic>)
        : null,
    history: (json['history'] as List)
        .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
        .toList(),
    sessionId: json['sessionId'] as String?,
    apiConfig: ApiConfig.fromJson(json['apiConfig'] as Map<String, dynamic>),
    sessionVars: Map<String, String>.from(json['sessionVars'] as Map? ?? {}),
    globalVars: Map<String, String>.from(json['globalVars'] as Map? ?? {}),
    summaryContent: json['summaryContent'] as String?,
    summaryPrefix: json['summaryPrefix'] as String?,
    memoryContent: json['memoryContent'] as String?,
    memoryMacroContent: json['memoryMacroContent'] as String?,
    memoryInjectionTarget: migrateInjectionTarget(
      json['memoryInjectionTarget'] as String?,
    ),
    guidanceText: json['guidanceText'] as String?,
    lorebooks: (json['lorebooks'] as List)
        .map((l) => Lorebook.fromJson(l as Map<String, dynamic>))
        .toList(),
    lorebookSettings: LorebookGlobalSettings.fromJson(
      json['lorebookSettings'] as Map<String, dynamic>,
    ),
    lorebookActivations: LorebookActivations.fromJson(
      json['lorebookActivations'] as Map<String, dynamic>,
    ),
    vectorEntries: (json['vectorEntries'] as List)
        .map((e) => LorebookEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
    authorsNote: json['authorsNote'] != null
        ? AuthorsNote.fromJson(json['authorsNote'] as Map<String, dynamic>)
        : null,
    characterDepthPrompt: json['characterDepthPrompt'] as String? ?? '',
    characterDepthPromptDepth: json['characterDepthPromptDepth'] as int? ?? 4,
    characterDepthPromptRole:
        json['characterDepthPromptRole'] as String? ?? 'system',
    memoryCoverage: Map<String, dynamic>.from(
      json['memoryCoverage'] as Map? ?? {},
    ),
    globalRegexes: (json['globalRegexes'] as List)
        .map((r) => PresetRegex.fromJson(r as Map<String, dynamic>))
        .toList(),
    preScannedEntries: json['preScannedEntries'] != null
        ? (json['preScannedEntries'] as List)
              .map((e) => ScannedEntry.fromJson(e as Map<String, dynamic>))
              .toList()
        : null,
    triggeredMemories: (json['triggeredMemories'] as List? ?? [])
        .map((t) => TriggeredEntry.fromJson(t as Map<String, dynamic>))
        .toList(),
    runtimePromptBlocks: (json['runtimePromptBlocks'] as List? ?? [])
        .map(
          (block) => RuntimePromptBlock.fromJson(block as Map<String, dynamic>),
        )
        .toList(),
    memorySelection: deserializeMemorySelection(
      json['memorySelection'] as Map<String, dynamic>?,
    ),
    memoryExcerptingEnabled: json['memoryExcerptingEnabled'] as bool? ?? true,
    memoryPackingMode: json['memoryPackingMode'] as String? ?? 'hybrid',
    memoryExcerptTokensPerChunk:
        json['memoryExcerptTokensPerChunk'] as int? ??
        defaultMemoryExcerptTokensPerEntry,
    memoryExcerptChunksPerEntry:
        json['memoryExcerptChunksPerEntry'] as int? ??
        defaultMemoryExcerptChunksPerEntry,
    chunkFirstTopEntries: json['chunkFirstTopEntries'] as int? ?? 3,
    chunkFirstTopChunks: json['chunkFirstTopChunks'] as int? ?? 1,
    arcContent: json['arcContent'] as String?,
    entitiesContent: json['entitiesContent'] as String?,
    studioSessionStateContent: json['studioSessionStateContent'] as String?,
    characterKnowledgeContent: json['characterKnowledgeContent'] as String?,
    recalledMessagesContent: json['recalledMessagesContent'] as String?,
    recalledMessageChunks: (json['recalledMessageChunks'] as List? ?? const [])
        .map((c) => RecalledMessageChunk.fromJson(c as Map<String, dynamic>))
        .toList(),
    disableSourceWindowExclusion:
        json['disableSourceWindowExclusion'] as bool? ?? false,
    sourceWindowVisibleMessageIds:
        (json['sourceWindowVisibleMessageIds'] as List? ?? const [])
            .cast<String>()
            .toSet(),
    memoryInjectionFingerprint:
        json['memoryInjectionFingerprint'] as String? ?? '',
  );
}

Map<String, dynamic> serializeResult(PromptResult r) => {
  'messages': r.messages.map((m) => m.toJson()).toList(),
  'breakdown': r.breakdown.toJson(),
  'sessionVars': r.sessionVars,
  'globalVars': r.globalVars,
  'triggeredLorebooks': r.triggeredLorebooks.map((t) => t.toJson()).toList(),
  'triggeredMemories': r.triggeredMemories.map((t) => t.toJson()).toList(),
  'memoryCoverage': r.memoryCoverage,
};

Map<String, dynamic>? serializeMemorySelection(MemorySelection? selection) {
  if (selection == null) return null;
  return {
    'selectionMode': selection.selectionMode,
    'entries': selection.entries.map((entry) => entry.toJson()).toList(),
    'allScores': selection.allScores.map(serializeMemoryScore).toList(),
    'totalTokens': selection.totalTokens,
    'budgetTokens': selection.budgetTokens,
    'entryCap': selection.entryCap,
    'budgetTrimmed': selection.budgetTrimmed,
    'excludedBySourceWindow': selection.excludedBySourceWindow,
  };
}

Map<String, dynamic> serializeMemoryScore(MemoryCandidateScore score) => {
  'entry': score.entry.toJson(),
  'score': score.score,
  'keywordScore': score.keywordScore,
  'vectorScore': score.vectorScore,
  'recencyScore': score.recencyScore,
  'importanceScore': score.importanceScore,
  'catalogScore': score.catalogScore,
  'diversityPenalty': score.diversityPenalty,
  'matchedKeys': score.matchedKeys,
  'catalogMatchedTerms': score.catalogMatchedTerms,
  'vectorMatchedChunks': score.vectorMatchedChunks,
  'excludedBySourceWindow': score.excludedBySourceWindow,
  'exclusionReason': score.exclusionReason,
};

MemorySelection? deserializeMemorySelection(Map<String, dynamic>? json) {
  if (json == null) return null;
  return MemorySelection(
    selectionMode: json['selectionMode'] as String? ?? 'v2',
    entries: (json['entries'] as List? ?? [])
        .map((entry) => MemoryEntry.fromJson(entry as Map<String, dynamic>))
        .toList(),
    allScores: (json['allScores'] as List? ?? [])
        .map((score) => deserializeMemoryScore(score as Map<String, dynamic>))
        .toList(),
    totalTokens: json['totalTokens'] as int? ?? 0,
    budgetTokens: json['budgetTokens'] as int?,
    entryCap: json['entryCap'] as int? ?? 0,
    budgetTrimmed: json['budgetTrimmed'] as bool? ?? false,
    excludedBySourceWindow: json['excludedBySourceWindow'] as int? ?? 0,
  );
}

MemoryCandidateScore deserializeMemoryScore(Map<String, dynamic> json) =>
    MemoryCandidateScore(
      entry: MemoryEntry.fromJson(json['entry'] as Map<String, dynamic>),
      score: (json['score'] as num?)?.toDouble() ?? 0,
      keywordScore: (json['keywordScore'] as num?)?.toDouble() ?? 0,
      vectorScore: (json['vectorScore'] as num?)?.toDouble() ?? 0,
      recencyScore: (json['recencyScore'] as num?)?.toDouble() ?? 0,
      importanceScore: (json['importanceScore'] as num?)?.toDouble() ?? 0,
      catalogScore: (json['catalogScore'] as num?)?.toDouble() ?? 0,
      diversityPenalty: (json['diversityPenalty'] as num?)?.toDouble() ?? 0,
      matchedKeys: (json['matchedKeys'] as List? ?? []).cast<String>(),
      catalogMatchedTerms: (json['catalogMatchedTerms'] as List? ?? [])
          .cast<String>(),
      vectorMatchedChunks: (json['vectorMatchedChunks'] as List? ?? [])
          .cast<String>(),
      excludedBySourceWindow: json['excludedBySourceWindow'] as bool? ?? false,
      exclusionReason: json['exclusionReason'] as String?,
    );

/// Translates the legacy `summary_block` / `summary_macro` enum values
/// (pre-{{memory}}-split) to `hard_block` / `macro`.
String migrateInjectionTarget(String? raw) {
  if (raw == 'summary_block') return 'hard_block';
  if (raw == 'summary_macro') return 'macro';
  return raw ?? 'hard_block';
}
