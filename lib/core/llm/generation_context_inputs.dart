import '../models/api_config.dart';
import '../models/character.dart';
import '../models/chat_message.dart'
    show AuthorsNote, ChatMessage, TriggeredEntry;
import '../models/lorebook.dart'
    show Lorebook, LorebookActivations, LorebookEntry, LorebookGlobalSettings;
import '../models/persona.dart';
import '../models/ledger_prompt_injection_mode.dart';
import '../models/ledger_prompt_injection_policy.dart';
import '../models/preset.dart' show PresetRegex;
import 'lorebook_scanner.dart' show ScannedEntry;
import 'memory_excerpt_selector.dart'
    show defaultMemoryExcerptChunksPerEntry, defaultMemoryExcerptTokensPerEntry;
import 'memory_selector.dart' show MemorySelection;
import 'prompt/effective_canon_prompt_formatter.dart';
import 'prompt/recalled_message_chunk.dart';
import 'prompt/runtime_prompt_block.dart';

/// Preset-neutral source data collected for a generation turn.
///
/// Ordinary and Studio compilers may derive their own request-specific context
/// from this snapshot. In particular, this contract must not acquire an
/// ordinary preset or preset block.
class GenerationContextInputs {
  final Character character;
  final Persona? persona;
  final List<ChatMessage> history;
  final String? sessionId;
  final ApiConfig apiConfig;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final String? summaryContent;
  final String? summaryPrefix;
  final String? memoryContent;
  final String? memoryMacroContent;
  final String memoryInjectionTarget;
  final String? guidanceText;

  /// Continue mode: system instruction injected right after the last history
  /// message. Null on every other path. See `docs/INVARIANTS.md` INV-CM3.
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

  /// Product-wide regex policy. Ordinary-preset regexes are not collected here.
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
  final String? studioSessionStateContent;

  /// In-game clock from ledger `world:*` trackers for `{{gametime}}` /
  /// `{{gamedate}}` / `{{gameday}}` macros. Null when no clock is tracked.
  final String? gameTime;
  final String? gameDate;
  final String? gameDay;
  final String? characterKnowledgeContent;
  final String? recalledMessagesContent;
  final List<RecalledMessageChunk> recalledMessageChunks;
  final String memoryInjectionFingerprint;
  final EffectiveCanonPromptProjection? effectiveCanonProjection;
  final int? effectiveCanonRevisionNumber;
  final String? effectiveCanonRevisionHash;
  final String effectiveCanonCacheIdentity;
  final LedgerPromptInjectionPolicy ledgerPromptInjectionPolicy;
  final String ledgerInjectionCacheIdentity;
  final bool ledgerProjectionFreshnessProvenCurrent;

  const GenerationContextInputs({
    required this.character,
    this.persona,
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
}
