import 'package:drift/drift.dart';

@DataClassName('CharacterRow')
class Characters extends Table {
  @override
  String get tableName => 'characters';

  TextColumn get charId => text()();
  TextColumn get name => text()();
  TextColumn get avatarPath => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get personality => text().nullable()();
  TextColumn get scenario => text().nullable()();
  TextColumn get firstMes => text().nullable()();
  TextColumn get mesExample => text().nullable()();
  TextColumn get systemPrompt => text().nullable()();
  TextColumn get postHistoryInstructions => text().nullable()();
  TextColumn get creator => text().nullable()();
  TextColumn get creatorNotes => text().nullable()();
  TextColumn get color => text().nullable()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  TextColumn get tagsJson => text().nullable()();
  TextColumn get alternateGreetingsJson => text().nullable()();
  TextColumn get galleryJson => text().nullable()();
  IntColumn get currentSessionIndex =>
      integer().withDefault(const Constant(0))();
  BoolColumn get fav => boolean().withDefault(const Constant(false))();
  TextColumn get extensionsJson => text().nullable()();
  TextColumn get characterVersion => text().withDefault(const Constant('1'))();
  TextColumn get macroName => text().nullable()();
  TextColumn get picksHash => text().nullable()();
  IntColumn get tokenCount => integer().withDefault(const Constant(0))();

  // Variations: each row is a full character card, but rows sharing a
  // [variantGroupId] are presented as a single entry in the My Characters list.
  // The representative ("cover") is the row with the lowest [variantOrder] (0).
  // For a standalone character, variantGroupId equals its own charId.
  TextColumn get variantGroupId => text().withDefault(const Constant(''))();
  TextColumn get variantName => text().nullable()();
  IntColumn get variantOrder => integer().withDefault(const Constant(0))();

  // Hidden characters are excluded from the My Characters list (and its count)
  // unless the user reveals them via the secret gesture (10 taps on the
  // Characters tab within 1.5s). Applied group-wide for a variation group.
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {charId};
}

@DataClassName('CharacterFolderRow')
class CharacterFolders extends Table {
  @override
  String get tableName => 'character_folders';

  TextColumn get folderId => text()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {folderId};
}

@DataClassName('CharacterFolderMemberRow')
@TableIndex(name: 'idx_cfm_folder', columns: {#folderId})
@TableIndex(name: 'idx_cfm_char', columns: {#charId})
class CharacterFolderMembers extends Table {
  @override
  String get tableName => 'character_folder_members';

  TextColumn get folderId => text()();
  TextColumn get charId => text()();
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

  // Composite PK: a character can live in many folders (same charId across
  // different folderId rows), but cannot be duplicated within one folder.
  @override
  Set<Column> get primaryKey => {folderId, charId};
}

@DataClassName('ChatSessionRow')
@TableIndex(name: 'idx_chat_sessions_character_id', columns: {#characterId})
@TableIndex(name: 'idx_chat_sessions_updated_at', columns: {#updatedAt})
class ChatSessions extends Table {
  @override
  String get tableName => 'chat_sessions';

  TextColumn get sessionId => text()();
  TextColumn get characterId => text()();
  IntColumn get sessionIndex => integer()();
  TextColumn get messagesJson => text()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  TextColumn get sessionVarsJson => text().nullable()();
  TextColumn get authorsNoteJson => text().nullable()();
  TextColumn get draft => text().nullable()();
  TextColumn get lastScrollAnchorJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {sessionId};
}

@DataClassName('MemoryBookRow')
class MemoryBookRows extends Table {
  @override
  String get tableName => 'memory_book_rows';

  TextColumn get sessionId => text()();
  TextColumn get entriesJson => text().withDefault(const Constant('[]'))();
  TextColumn get pendingDraftsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get settingsJson => text().withDefault(const Constant('{}'))();
  IntColumn get lastProcessedMessageCount =>
      integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId};
}

@DataClassName('MemoryCatalogRow')
@TableIndex(
  name: 'idx_memory_catalog_session_entry',
  columns: {#chatSessionId, #memoryEntryId},
)
@TableIndex(name: 'idx_memory_catalog_stale', columns: {#stale})
class MemoryCatalogRows extends Table {
  @override
  String get tableName => 'memory_catalog_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get memoryEntryId => text()();
  TextColumn get entryRevision => text().withDefault(const Constant(''))();
  TextColumn get sourceHash => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get keysJson => text().withDefault(const Constant('[]'))();
  TextColumn get entitiesJson => text().withDefault(const Constant('[]'))();
  TextColumn get locationsJson => text().withDefault(const Constant('[]'))();
  TextColumn get topicsJson => text().withDefault(const Constant('[]'))();
  IntColumn get messageRangeStart => integer().nullable()();
  IntColumn get messageRangeEnd => integer().nullable()();
  RealColumn get importance => real().withDefault(const Constant(0.0))();
  BoolColumn get temporallyBlind =>
      boolean().withDefault(const Constant(false))();
  IntColumn get tokenCount => integer().withDefault(const Constant(0))();
  TextColumn get abstractText => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  BoolColumn get stale => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemoryEntityRow')
@TableIndex(
  name: 'idx_memory_entity_session_name',
  columns: {#chatSessionId, #name},
)
@TableIndex(
  name: 'idx_memory_entity_session_type',
  columns: {#chatSessionId, #entityType},
)
@TableIndex(name: 'idx_memory_entity_entry', columns: {#memoryEntryId})
class MemoryEntityRows extends Table {
  @override
  String get tableName => 'memory_entity_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get memoryEntryId => text()();
  TextColumn get name => text()();
  TextColumn get entityType =>
      text().withDefault(const Constant('character'))();
  TextColumn get aliasesJson => text().withDefault(const Constant('[]'))();
  TextColumn get description => text().withDefault(const Constant(''))();
  RealColumn get salienceAvg => real().withDefault(const Constant(0.0))();
  RealColumn get saliencePeak => real().withDefault(const Constant(0.0))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get factsJson => text().withDefault(const Constant('[]'))();
  TextColumn get emotionalValenceJson =>
      text().withDefault(const Constant('{}'))();
  IntColumn get mentionCount => integer().withDefault(const Constant(0))();
  IntColumn get lastSeenMessageIndex =>
      integer().withDefault(const Constant(0))();
  TextColumn get sourceHash => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemorySalienceRow')
@TableIndex(name: 'idx_memory_salience_session', columns: {#chatSessionId})
@TableIndex(name: 'idx_memory_salience_entry', columns: {#memoryEntryId})
class MemorySalienceRows extends Table {
  @override
  String get tableName => 'memory_salience_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get memoryEntryId => text()();
  RealColumn get score => real().withDefault(const Constant(0.0))();
  TextColumn get emotionalTagsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get narrativeFlagsJson =>
      text().withDefault(const Constant('[]'))();
  BoolColumn get hasDialogue => boolean().withDefault(const Constant(false))();
  BoolColumn get hasAction => boolean().withDefault(const Constant(false))();
  IntColumn get wordCount => integer().withDefault(const Constant(0))();
  TextColumn get scoreSource =>
      text().withDefault(const Constant('heuristic'))();
  IntColumn get scoredAt => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemoryCadenceRow')
class MemoryCadenceRows extends Table {
  @override
  String get tableName => 'memory_cadence_rows';

  TextColumn get chatSessionId => text()();
  IntColumn get assistantMessagesSinceLastRun =>
      integer().withDefault(const Constant(0))();
  IntColumn get lastRunMessageIndex =>
      integer().withDefault(const Constant(0))();
  IntColumn get lastRunAt => integer().withDefault(const Constant(0))();
  TextColumn get lastRunKind => text().withDefault(const Constant('graph'))();

  @override
  Set<Column> get primaryKey => {chatSessionId};
}

@DataClassName('MemoryConsolidationRow')
@TableIndex(
  name: 'idx_memory_consolidation_session_tier',
  columns: {#chatSessionId, #tier},
)
@TableIndex(
  name: 'idx_memory_consolidation_session_status',
  columns: {#chatSessionId, #status},
)
class MemoryConsolidationRows extends Table {
  @override
  String get tableName => 'memory_consolidation_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  IntColumn get tier => integer().withDefault(const Constant(1))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get summary => text().withDefault(const Constant(''))();
  TextColumn get sourceEntryIdsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get entityIdsJson => text().withDefault(const Constant('[]'))();
  IntColumn get messageRangeStart => integer().withDefault(const Constant(0))();
  IntColumn get messageRangeEnd => integer().withDefault(const Constant(0))();
  RealColumn get salienceAvg => real().withDefault(const Constant(0.0))();
  TextColumn get emotionalTagsJson =>
      text().withDefault(const Constant('[]'))();
  IntColumn get tokenCount => integer().withDefault(const Constant(0))();
  TextColumn get sourceModel => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get errorMessage => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('TrackerRow')
@TableIndex(name: 'idx_trackers_session', columns: {#sessionId})
@TableIndex(name: 'idx_trackers_session_scope', columns: {#sessionId, #scope})
class TrackerRows extends Table {
  @override
  String get tableName => 'tracker_rows';

  TextColumn get sessionId => text()();
  TextColumn get name => text()();
  TextColumn get value => text().withDefault(const Constant(''))();
  // Reserved for future cross-scope trackers (chat/character/global). For the
  // agentic MVP, trackers are session-scoped ('chat' default).
  TextColumn get scope => text().withDefault(const Constant('chat'))();
  // Provenance: which agent/turn wrote this tracker (e.g.
  // 'memory_agent:msg_10'). For debugging and cache invalidation.
  TextColumn get provenance => text().withDefault(const Constant(''))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  // Composite PK: one value per (session, tracker name). upsert via
  // insertOnConflictUpdate targets this natural key.
  @override
  Set<Column> get primaryKey => {sessionId, name};
}

/// Per-(message, swipe, agent-swipe) immutable tracker state snapshot.
///
/// Mirrors Marinara-Engine's `game_state_snapshots` model: each swipe of each
/// message owns its own tracker state row, so delete/swipe/regen rollback is
/// emergent (delete the rows; the previous committed snapshot becomes
/// "latest"). The `committed` flag separates accepted state (user sent a
/// follow-up) from tentative/regen state.
///
/// Keyed by `(sessionId, messageId, swipeId, agentSwipeId)` so branching a
/// session (which preserves `ChatMessage.id` across the slice) does not
/// alias across sessions — the `sessionId` prefix isolates each branch's
/// snapshots. `trackersJson` is a JSON array of `Tracker.toJson()` entries.
@DataClassName('TrackerSnapshotRow')
@TableIndex(name: 'idx_tracker_snapshots_session', columns: {#sessionId})
@TableIndex(
  name: 'idx_tracker_snapshots_session_message',
  columns: {#sessionId, #messageId},
)
@TableIndex(
  name: 'idx_tracker_snapshots_session_committed',
  columns: {#sessionId, #committed},
)
class TrackerSnapshots extends Table {
  @override
  String get tableName => 'tracker_snapshots';

  TextColumn get sessionId => text()();
  TextColumn get messageId => text()();
  IntColumn get swipeId => integer().withDefault(const Constant(0))();
  IntColumn get agentSwipeId => integer().withDefault(const Constant(0))();
  TextColumn get trackersJson => text().withDefault(const Constant('[]'))();
  IntColumn get committed => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId, messageId, swipeId, agentSwipeId};
}

/// Last successfully reconciled Ledger message range for a chat session.
@DataClassName('LedgerReconciliationCheckpointRow')
class LedgerReconciliationCheckpoints extends Table {
  @override
  String get tableName => 'ledger_reconciliation_checkpoints';

  TextColumn get sessionId => text()();
  TextColumn get startMessageId => text()();
  TextColumn get endMessageId => text()();
  IntColumn get endSwipeId => integer().withDefault(const Constant(0))();
  IntColumn get endAgentSwipeId => integer().withDefault(const Constant(0))();
  TextColumn get messageIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get rangeHash => text().withDefault(const Constant(''))();
  IntColumn get reviewedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId};
}

/// Before-images for reversible knowledge cleanup performed by reconciliation.
@DataClassName('LedgerReconciliationCleanupJournalRow')
class LedgerReconciliationCleanupJournals extends Table {
  @override
  String get tableName => 'ledger_reconciliation_cleanup_journals';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text()();
  TextColumn get endpointMessageId => text()();
  TextColumn get messageIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get beforeImagesJson => text().withDefault(const Constant('[]'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
}

/// Append-only, provenance-backed character knowledge and development delta.
/// Corrections point to prior rows; the earlier row remains inspectable.
@DataClassName('CharacterKnowledgeFactRow')
@TableIndex(
  name: 'idx_character_knowledge_fact_session_lifecycle_knower',
  columns: {#chatSessionId, #lifecycle, #knowerKey},
)
@TableIndex(
  name: 'idx_character_knowledge_fact_session_lifecycle_subject',
  columns: {#chatSessionId, #lifecycle, #subjectKey},
)
@TableIndex(
  name: 'idx_character_knowledge_fact_source_anchor',
  columns: {
    #chatSessionId,
    #sourceMessageId,
    #sourceSwipeId,
    #sourceAgentSwipeId,
  },
)
@TableIndex(
  name: 'idx_character_knowledge_fact_session_supersedes',
  columns: {#chatSessionId, #supersedesId},
)
class CharacterKnowledgeFactRows extends Table {
  @override
  String get tableName => 'character_knowledge_fact_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get knowerKey => text()();
  TextColumn get knowerName => text().withDefault(const Constant(''))();
  TextColumn get subjectKey => text()();
  TextColumn get subjectName => text().withDefault(const Constant(''))();
  TextColumn get factClass => text()();
  TextColumn get scopeKey => text().withDefault(const Constant(''))();
  TextColumn get predicate => text()();
  TextColumn get object => text()();
  TextColumn get epistemicState => text()();
  RealColumn get confidence => real().withDefault(const Constant(0.0))();
  RealColumn get importance => real().withDefault(const Constant(0.0))();
  TextColumn get entitiesJson => text().withDefault(const Constant('[]'))();
  TextColumn get topicsJson => text().withDefault(const Constant('[]'))();
  TextColumn get sourceMessageId => text().withDefault(const Constant(''))();
  IntColumn get sourceSwipeId => integer().withDefault(const Constant(0))();
  IntColumn get sourceAgentSwipeId =>
      integer().withDefault(const Constant(0))();
  TextColumn get sourceKind =>
      text().withDefault(const Constant('studio_ledger'))();
  TextColumn get supersedesId => text().nullable()();
  TextColumn get lifecycle => text().withDefault(const Constant('tentative'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Immutable source-card revision selected for a session.
/// Session development remains in [CharacterKnowledgeFactRows].
@DataClassName('CharacterSessionBaselineRow')
class CharacterSessionBaselineRows extends Table {
  @override
  String get tableName => 'character_session_baseline_rows';

  TextColumn get chatSessionId => text()();
  TextColumn get characterId => text()();
  TextColumn get baselineCardJson => text()();
  TextColumn get baselineHash => text()();
  TextColumn get sourceHashLastSeen => text().withDefault(const Constant(''))();
  TextColumn get cardUpdatePolicy =>
      text().withDefault(const Constant('follow_source'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {chatSessionId};
}

@DataClassName('StudioConfigRow')
@TableIndex(name: 'idx_studio_config_session', columns: {#sessionId})
class StudioConfigRows extends Table {
  @override
  String get tableName => 'studio_config_rows';

  TextColumn get sessionId => text()();
  TextColumn get profileId => text().withDefault(const Constant(''))();
  TextColumn get profileName => text().withDefault(const Constant(''))();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  TextColumn get agentsJson => text().withDefault(const Constant('[]'))();
  TextColumn get finalPresetId => text().withDefault(const Constant(''))();
  TextColumn get runApiConfigId => text().withDefault(const Constant(''))();
  TextColumn get expensiveApiConfigId =>
      text().withDefault(const Constant(''))();
  TextColumn get cheapApiConfigId => text().withDefault(const Constant(''))();
  TextColumn get cleanerApiConfigId => text().withDefault(const Constant(''))();
  TextColumn get runModelOverride => text().withDefault(const Constant(''))();
  IntColumn get maxFinalHistoryMessages =>
      integer().withDefault(const Constant(30))();
  TextColumn get broadcastBlocksJson =>
      text().withDefault(const Constant('[]'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId};
}

@DataClassName('StudioPresetRow')
class StudioPresetRows extends Table {
  @override
  String get tableName => 'studio_preset_rows';

  TextColumn get presetId => text()();
  TextColumn get name => text()();
  TextColumn get blocksJson => text().withDefault(const Constant('[]'))();
  TextColumn get agentEnabledJson => text().withDefault(const Constant('{}'))();
  TextColumn get executionMode =>
      text().withDefault(const Constant('legacy'))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {presetId};
}

@DataClassName('PresetRow')
class Presets extends Table {
  @override
  String get tableName => 'presets';

  TextColumn get presetId => text()();
  TextColumn get name => text()();
  TextColumn get dataJson => text()();

  @override
  Set<Column> get primaryKey => {presetId};
}

@DataClassName('ApiConfigRow')
class ApiConfigs extends Table {
  @override
  String get tableName => 'api_configs';

  TextColumn get configId => text()();
  TextColumn get name => text()();
  TextColumn get providerId =>
      text().withDefault(const Constant('openai_compatible'))();
  TextColumn get protocol => text().withDefault(const Constant('openai'))();
  TextColumn get endpoint => text().nullable()();
  TextColumn get apiKey => text().nullable()();
  TextColumn get model => text().nullable()();
  TextColumn get mode => text().withDefault(const Constant('chat'))();
  IntColumn get maxTokens => integer().withDefault(const Constant(8000))();
  IntColumn get contextSize => integer().withDefault(const Constant(32000))();
  RealColumn get temperature => real().withDefault(const Constant(0.7))();
  RealColumn get topP => real().withDefault(const Constant(0.9))();
  IntColumn get topK => integer().withDefault(const Constant(0))();
  RealColumn get frequencyPenalty => real().withDefault(const Constant(0.0))();
  RealColumn get presencePenalty => real().withDefault(const Constant(0.0))();
  BoolColumn get stream => boolean().withDefault(const Constant(true))();
  TextColumn get reasoningEffort => text().nullable()();
  BoolColumn get requestReasoning =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get useResponsesApi =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get showNativeReasoning =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get includeLastReasoning =>
      boolean().withDefault(const Constant(false))();
  IntColumn get reasoningHistoryCount =>
      integer().withDefault(const Constant(0))();
  TextColumn get reasoningTagStart => text().nullable()();
  TextColumn get reasoningTagEnd => text().nullable()();
  BoolColumn get omitTemperature =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get omitTopP => boolean().withDefault(const Constant(false))();
  BoolColumn get omitTopK => boolean().withDefault(const Constant(false))();
  BoolColumn get omitFrequencyPenalty =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get omitPresencePenalty =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get omitReasoning =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get omitReasoningEffort =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get embeddingUseSame =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get embeddingEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get embeddingEndpoint => text().nullable()();
  TextColumn get embeddingApiKey => text().nullable()();
  TextColumn get embeddingModel => text().nullable()();
  IntColumn get embeddingMaxChunkTokens =>
      integer().withDefault(const Constant(512))();
  TextColumn get cacheControlTtl => text().withDefault(const Constant('off'))();
  TextColumn get cacheBreakpointMode =>
      text().withDefault(const Constant('depth'))();
  TextColumn get sessionIdMode =>
      text().withDefault(const Constant('openrouter'))();
  IntColumn get firstChunkTimeoutMs =>
      integer().withDefault(const Constant(60000))();
  TextColumn get extraRequestParametersJson =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {configId};
}

@DataClassName('PersonaRow')
class Personas extends Table {
  @override
  String get tableName => 'personas';

  TextColumn get personaId => text()();
  TextColumn get name => text()();
  TextColumn get prompt => text().nullable()();
  TextColumn get avatarPath => text().nullable()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {personaId};
}

@DataClassName('LorebookRow')
@TableIndex(name: 'idx_lorebooks_activation_scope', columns: {#activationScope})
@TableIndex(
  name: 'idx_lorebooks_activation_target_id',
  columns: {#activationTargetId},
)
class Lorebooks extends Table {
  @override
  String get tableName => 'lorebooks';

  TextColumn get lorebookId => text()();
  TextColumn get name => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get activationScope =>
      text().withDefault(const Constant('global'))();
  TextColumn get activationTargetId => text().nullable()();
  TextColumn get entriesJson => text()();
  TextColumn get settingsJson => text().withDefault(const Constant(''))();
  TextColumn get description => text().withDefault(const Constant(''))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {lorebookId};
}

@DataClassName('EmbeddingRow')
@TableIndex(name: 'idx_embeddings_source_type', columns: {#sourceType})
@TableIndex(name: 'idx_embeddings_source_id', columns: {#sourceId})
@TableIndex(
  name: 'idx_embeddings_source_type_id',
  columns: {#sourceType, #sourceId},
)
class Embeddings extends Table {
  @override
  String get tableName => 'embeddings';

  TextColumn get entryId => text()();
  TextColumn get sourceType =>
      text().withDefault(const Constant('lorebook_entry'))();
  TextColumn get sourceId => text().nullable()();
  BlobColumn get vectorsBlob => blob().nullable()();
  TextColumn get textHash => text().nullable()();
  TextColumn get retrievalHintsJson => text().nullable()();
  TextColumn get errorJson => text().nullable()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {entryId};
}

@DataClassName('ChatSummary')
class ChatSummaries extends Table {
  @override
  String get tableName => 'chat_summaries';

  TextColumn get sessionId => text()();
  TextColumn get content => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get messageCount => integer().withDefault(const Constant(0))();
  TextColumn get prompt => text().nullable()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId};
}

@DataClassName('ExtensionPresetRow')
class ExtensionPresets extends Table {
  @override
  String get tableName => 'extension_presets';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get configJson => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('InfoBlockRow')
@TableIndex(name: 'idx_info_blocks_session_id', columns: {#sessionId})
@TableIndex(name: 'idx_info_blocks_message_id', columns: {#messageId})
@TableIndex(
  name: 'idx_info_blocks_message_swipe',
  columns: {#messageId, #swipeId},
)
@TableIndex(
  name: 'idx_info_blocks_message_agent_swipe',
  columns: {#messageId, #swipeId, #agentSwipeId},
)
class InfoBlocks extends Table {
  @override
  String get tableName => 'info_blocks';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get messageId => text()();
  IntColumn get swipeId => integer().withDefault(const Constant(0))();
  IntColumn get agentSwipeId => integer().withDefault(const Constant(-1))();
  TextColumn get blockId => text()();
  TextColumn get blockName => text()();
  TextColumn get blockType => text()();
  TextColumn get content => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get order_ =>
      integer().named('order').withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('done'))();

  @override
  Set<Column> get primaryKey => {id};
}
