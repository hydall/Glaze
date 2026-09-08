import '../models/character.dart';
import '../models/persona.dart';
import '../models/preset.dart';
import '../models/chat_message.dart';
import '../models/api_config.dart';
import '../models/lorebook.dart';
import '../models/memory_book.dart';
import 'prompt_builder.dart';

/// Raw inputs collected from DB/providers on the main thread.
/// Fully serializable for cross-isolate transfer.
/// The isolate uses these to run memory keyword matching, lorebook scanning,
/// prompt assembly, and tokenization without blocking the UI.
class PromptInputs {
  final Character character;
  final Persona? persona;
  final Preset? preset;
  final List<ChatMessage> history;
  final String? sessionId;
  final ApiConfig apiConfig;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final String? summaryContent;
  final String? guidanceText;
  final List<Lorebook> lorebooks;
  final LorebookGlobalSettings lorebookSettings;
  final LorebookActivations lorebookActivations;
  final AuthorsNote? authorsNote;
  final String characterDepthPrompt;
  final int characterDepthPromptDepth;
  final String characterDepthPromptRole;
  final List<PresetRegex> globalRegexes;
  final List<LorebookEntry> vectorEntries;

  // Memory injection raw data (keyword matching only, no vector search)
  final List<MemoryEntry> memoryEntries;
  final bool memoryEnabled;
  final String memoryMode;
  final int memoryMaxInjected;
  final bool memoryExcerptingEnabled;
  final String memoryPackingMode;
  final int memoryExcerptTokensPerChunk;
  final int memoryExcerptChunksPerEntry;
  final int chunkFirstTopEntries;
  final int chunkFirstTopChunks;
  final String memoryKeyMatchMode;
  final String memoryInjectionTarget;
  // v2 selector knobs (see MemorySelector / MemoryBookSettings).
  final int? memoryMaxInjectedTokens;
  final double memoryMaxInjectionBudgetPercent;
  final bool memoryDiversityAware;
  final double memoryDiversityPenalty;
  final bool memoryRecencyBoost;
  final double memoryRecencyHalfLifeDays;
  final bool memoryImportanceBoost;
  final double memoryImportanceWeight;
  final bool memorySourceWindowExclusion;
  final bool memoryQueryIncludeAssistant;
  final int memoryQueryRecentTurns;
  final int memoryQueryMaxChars;
  final int memoryContextBudgetTokens;
  final List<RuntimePromptBlock> runtimePromptBlocks;

  const PromptInputs({
    required this.character,
    this.persona,
    this.preset,
    required this.history,
    this.sessionId,
    required this.apiConfig,
    this.sessionVars = const {},
    this.globalVars = const {},
    this.summaryContent,
    this.guidanceText,
    this.lorebooks = const [],
    this.lorebookSettings = const LorebookGlobalSettings(),
    this.lorebookActivations = const LorebookActivations(),
    this.authorsNote,
    this.characterDepthPrompt = '',
    this.characterDepthPromptDepth = 4,
    this.characterDepthPromptRole = 'system',
    this.globalRegexes = const [],
    this.vectorEntries = const [],
    this.memoryEntries = const [],
    this.memoryEnabled = true,
    this.memoryMode = 'fast',
    this.memoryMaxInjected = 7,
    this.memoryExcerptingEnabled = true,
    this.memoryPackingMode = 'hybrid',
    this.memoryExcerptTokensPerChunk = 500,
    this.memoryExcerptChunksPerEntry = 2,
    this.chunkFirstTopEntries = 3,
    this.chunkFirstTopChunks = 1,
    this.memoryKeyMatchMode = 'glaze',
    this.memoryInjectionTarget = 'hard_block',
    this.memoryMaxInjectedTokens,
    this.memoryMaxInjectionBudgetPercent = 0.35,
    this.memoryDiversityAware = true,
    this.memoryDiversityPenalty = 0.15,
    this.memoryRecencyBoost = true,
    this.memoryRecencyHalfLifeDays = 100,
    this.memoryImportanceBoost = true,
    this.memoryImportanceWeight = 0.5,
    this.memorySourceWindowExclusion = true,
    this.memoryQueryIncludeAssistant = true,
    this.memoryQueryRecentTurns = 6,
    this.memoryQueryMaxChars = 1500,
    this.memoryContextBudgetTokens = 0,
    this.runtimePromptBlocks = const [],
  });

  Map<String, dynamic> toJson() => {
    'character': character.toJson(),
    'persona': persona?.toJson(),
    'preset': preset?.toJson(),
    'history': history.map((m) => m.toJson()).toList(),
    'sessionId': sessionId,
    'apiConfig': apiConfig.toJson(),
    'sessionVars': sessionVars,
    'globalVars': globalVars,
    'summaryContent': summaryContent,
    'guidanceText': guidanceText,
    'lorebooks': lorebooks.map((l) => l.toJson()).toList(),
    'lorebookSettings': lorebookSettings.toJson(),
    'lorebookActivations': lorebookActivations.toJson(),
    'authorsNote': authorsNote?.toJson(),
    'characterDepthPrompt': characterDepthPrompt,
    'characterDepthPromptDepth': characterDepthPromptDepth,
    'characterDepthPromptRole': characterDepthPromptRole,
    'globalRegexes': globalRegexes.map((r) => r.toJson()).toList(),
    'vectorEntries': vectorEntries.map((e) => e.toJson()).toList(),
    'memoryEntries': memoryEntries.map((e) => e.toJson()).toList(),
    'memoryEnabled': memoryEnabled,
    'memoryMode': memoryMode,
    'memoryMaxInjected': memoryMaxInjected,
    'memoryExcerptingEnabled': memoryExcerptingEnabled,
    'memoryPackingMode': memoryPackingMode,
    'memoryExcerptTokensPerChunk': memoryExcerptTokensPerChunk,
    'memoryExcerptChunksPerEntry': memoryExcerptChunksPerEntry,
    'chunkFirstTopEntries': chunkFirstTopEntries,
    'chunkFirstTopChunks': chunkFirstTopChunks,
    'memoryKeyMatchMode': memoryKeyMatchMode,
    'memoryInjectionTarget': _migrateInjectionTarget(memoryInjectionTarget),
    'memoryMaxInjectedTokens': memoryMaxInjectedTokens,
    'memoryMaxInjectionBudgetPercent': memoryMaxInjectionBudgetPercent,
    'memoryDiversityAware': memoryDiversityAware,
    'memoryDiversityPenalty': memoryDiversityPenalty,
    'memoryRecencyBoost': memoryRecencyBoost,
    'memoryRecencyHalfLifeDays': memoryRecencyHalfLifeDays,
    'memoryImportanceBoost': memoryImportanceBoost,
    'memoryImportanceWeight': memoryImportanceWeight,
    'memorySourceWindowExclusion': memorySourceWindowExclusion,
    'memoryQueryIncludeAssistant': memoryQueryIncludeAssistant,
    'memoryQueryRecentTurns': memoryQueryRecentTurns,
    'memoryQueryMaxChars': memoryQueryMaxChars,
    'memoryContextBudgetTokens': memoryContextBudgetTokens,
    'runtimePromptBlocks': runtimePromptBlocks
        .map((block) => block.toJson())
        .toList(),
  };

  factory PromptInputs.fromJson(Map<String, dynamic> json) => PromptInputs(
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
    authorsNote: json['authorsNote'] != null
        ? AuthorsNote.fromJson(json['authorsNote'] as Map<String, dynamic>)
        : null,
    characterDepthPrompt: json['characterDepthPrompt'] as String? ?? '',
    characterDepthPromptDepth: json['characterDepthPromptDepth'] as int? ?? 4,
    characterDepthPromptRole:
        json['characterDepthPromptRole'] as String? ?? 'system',
    globalRegexes: (json['globalRegexes'] as List)
        .map((r) => PresetRegex.fromJson(r as Map<String, dynamic>))
        .toList(),
    vectorEntries: (json['vectorEntries'] as List)
        .map((e) => LorebookEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
    memoryEntries: (json['memoryEntries'] as List)
        .map((e) => MemoryEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
    memoryEnabled: json['memoryEnabled'] as bool? ?? true,
    memoryMode: json['memoryMode'] as String? ?? 'fast',
    memoryMaxInjected: json['memoryMaxInjected'] as int? ?? 7,
    memoryExcerptingEnabled: json['memoryExcerptingEnabled'] as bool? ?? true,
    memoryPackingMode: json['memoryPackingMode'] as String? ?? 'hybrid',
    memoryExcerptTokensPerChunk:
        json['memoryExcerptTokensPerChunk'] as int? ?? 500,
    memoryExcerptChunksPerEntry:
        json['memoryExcerptChunksPerEntry'] as int? ?? 2,
    chunkFirstTopEntries: json['chunkFirstTopEntries'] as int? ?? 3,
    chunkFirstTopChunks: json['chunkFirstTopChunks'] as int? ?? 1,
    memoryKeyMatchMode: json['memoryKeyMatchMode'] as String? ?? 'glaze',
    memoryInjectionTarget: _migrateInjectionTarget(
      json['memoryInjectionTarget'] as String?,
    ),
    memoryMaxInjectedTokens: json['memoryMaxInjectedTokens'] as int?,
    memoryMaxInjectionBudgetPercent:
        (json['memoryMaxInjectionBudgetPercent'] as num?)?.toDouble() ?? 0.35,
    memoryDiversityAware: json['memoryDiversityAware'] as bool? ?? true,
    memoryDiversityPenalty:
        (json['memoryDiversityPenalty'] as num?)?.toDouble() ?? 0.15,
    memoryRecencyBoost: json['memoryRecencyBoost'] as bool? ?? true,
    memoryRecencyHalfLifeDays:
        (json['memoryRecencyHalfLifeDays'] as num?)?.toDouble() ?? 100,
    memoryImportanceBoost: json['memoryImportanceBoost'] as bool? ?? true,
    memoryImportanceWeight:
        (json['memoryImportanceWeight'] as num?)?.toDouble() ?? 0.5,
    memorySourceWindowExclusion:
        json['memorySourceWindowExclusion'] as bool? ?? true,
    memoryQueryIncludeAssistant:
        json['memoryQueryIncludeAssistant'] as bool? ?? true,
    memoryQueryRecentTurns: json['memoryQueryRecentTurns'] as int? ?? 6,
    memoryQueryMaxChars: json['memoryQueryMaxChars'] as int? ?? 1500,
    memoryContextBudgetTokens: json['memoryContextBudgetTokens'] as int? ?? 0,
    runtimePromptBlocks: (json['runtimePromptBlocks'] as List? ?? [])
        .map(
          (block) => RuntimePromptBlock.fromJson(block as Map<String, dynamic>),
        )
        .toList(),
  );
}

String _migrateInjectionTarget(String? raw) {
  if (raw == 'summary_block') return 'hard_block';
  if (raw == 'summary_macro') return 'macro';
  return raw ?? 'hard_block';
}
