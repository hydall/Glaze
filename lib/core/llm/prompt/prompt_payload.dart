import '../../models/character.dart';
import '../../models/persona.dart';
import '../../models/preset.dart' show Preset, PresetRegex;
import '../../models/chat_message.dart'
    show ChatMessage, AuthorsNote, TriggeredEntry;
import '../../models/api_config.dart';
import '../../models/lorebook.dart'
    show Lorebook, LorebookGlobalSettings, LorebookActivations, LorebookEntry;
import '../lorebook_scanner.dart' show ScannedEntry;
import '../memory_selector.dart' show MemorySelection;
import '../memory_excerpt_selector.dart'
    show defaultMemoryExcerptTokensPerEntry, defaultMemoryExcerptChunksPerEntry;
import 'runtime_prompt_block.dart';
import 'recalled_message_chunk.dart';

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
    this.characterKnowledgeContent,
    this.recalledMessagesContent,
    this.recalledMessageChunks = const [],
    this.disableSourceWindowExclusion = false,
    this.sourceWindowVisibleMessageIds = const {},
    this.memoryInjectionFingerprint = '',
  });
}
