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
  IntColumn get basisRevision => integer().withDefault(const Constant(0))();
  TextColumn get basisRevisionHash => text().withDefault(const Constant(''))();
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
  IntColumn get basisRevision => integer().withDefault(const Constant(0))();
  TextColumn get basisRevisionHash => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CharacterRevisionRow')
@TableIndex(
  name: 'idx_character_revision_hash',
  columns: {#characterId, #revisionHash},
)
class CharacterRevisionRows extends Table {
  @override
  String get tableName => 'character_revision_rows';

  TextColumn get characterId => text()();
  IntColumn get revision => integer()();
  TextColumn get revisionHash => text()();

  /// Hash of the immediately preceding revision; empty for the lineage root.
  TextColumn get parentRevisionHash => text().withDefault(const Constant(''))();
  TextColumn get snapshotJson => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {characterId, revision};
}

@DataClassName('AppliedCanonTransitionRow')
@TableIndex(
  name: 'idx_applied_canon_transition_session',
  columns: {#chatSessionId},
)
@TableIndex(
  name: 'idx_applied_canon_transition_character',
  columns: {#characterId},
)
@TableIndex(
  name: 'idx_applied_canon_transition_operation',
  columns: {#rewriteOperationId},
)
class AppliedCanonTransitionRows extends Table {
  @override
  String get tableName => 'applied_canon_transition_rows';

  TextColumn get id => text()();

  /// Null means a character-global transition, not owned by any chat session.
  TextColumn get chatSessionId => text().nullable()();
  TextColumn get characterId => text()();
  TextColumn get rewriteOperationId => text().withDefault(const Constant(''))();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  TextColumn get revisionHash => text().withDefault(const Constant(''))();
  TextColumn get semanticScopeKey => text().withDefault(const Constant(''))();
  TextColumn get canonicalClaim => text().withDefault(const Constant(''))();
  TextColumn get promotionDestination =>
      text().withDefault(const Constant(''))();
  TextColumn get affectedTrackerKeysJson =>
      text().withDefault(const Constant('[]'))();

  /// Legacy payload only; safety-critical fields above remain queryable.
  TextColumn get transitionJson => text()();
  IntColumn get basisRevision => integer().withDefault(const Constant(0))();
  TextColumn get basisRevisionHash => text().withDefault(const Constant(''))();
  IntColumn get appliedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('RewriteJobRow')
@TableIndex(name: 'idx_rewrite_job_session', columns: {#chatSessionId})
@TableIndex(
  name: 'idx_rewrite_job_request_key',
  columns: {#requestKey},
  unique: true,
)
class RewriteJobs extends Table {
  @override
  String get tableName => 'rewrite_jobs';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get characterId => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// Durable human-readable reason for failed/cancelled jobs; null otherwise.
  TextColumn get statusReason => text().nullable()();
  TextColumn get requestJson => text().withDefault(const Constant('{}'))();
  IntColumn get basisRevision => integer().withDefault(const Constant(0))();
  TextColumn get basisRevisionHash => text().withDefault(const Constant(''))();

  /// Effective-canon stamp captured when generation started. Audit/display
  /// only; guarded apply always re-derives the live stamp.
  TextColumn get canonStamp => text().withDefault(const Constant(''))();

  /// Optional caller idempotency key. The unique index keeps NULL keys
  /// distinct, so unkeyed jobs never collide.
  TextColumn get requestKey => text().nullable()();

  /// Monotonic aggregate CAS version. Legacy jobs begin at version one.
  IntColumn get version => integer().withDefault(const Constant(1))();
  IntColumn get appliedCharacterRevision =>
      integer().withDefault(const Constant(0))();
  TextColumn get appliedCharacterRevisionHash =>
      text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('generating', 'pending', 'failed', 'cancelled', "
        "'applied'))",
  ];
}

@DataClassName('RewriteOperationRow')
@TableIndex(name: 'idx_rewrite_operation_job', columns: {#rewriteJobId})
@TableIndex(name: 'idx_rewrite_operation_session', columns: {#chatSessionId})
@TableIndex(
  name: 'idx_rewrite_operation_apply_cas',
  columns: {#rewriteJobId, #decision, #validationStatus, #currentRevision},
)
class RewriteOperations extends Table {
  @override
  String get tableName => 'rewrite_operations';

  TextColumn get id => text()();
  TextColumn get rewriteJobId => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get operationJson => text().withDefault(const Constant('{}'))();
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// Current immutable operation-revision number selected by CAS.
  IntColumn get currentRevision => integer().withDefault(const Constant(1))();

  /// Durable reviewer decision: pending, approved, or rejected.
  TextColumn get decision => text().withDefault(const Constant('pending'))();

  /// Validation result bound to [decisionRevision].
  TextColumn get validationStatus =>
      text().withDefault(const Constant('pending'))();
  IntColumn get decisionRevision => integer().withDefault(const Constant(0))();
  IntColumn get appliedCharacterRevision =>
      integer().withDefault(const Constant(0))();
  TextColumn get appliedCharacterRevisionHash =>
      text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('pending', 'reviewable', 'applied'))",
    "CHECK (decision IN ('pending', 'approved', 'rejected'))",
    "CHECK (validation_status IN ('pending', 'valid', 'invalid'))",
    'CHECK (current_revision >= 1)',
    'CHECK (decision_revision >= 0)',
  ];
}

@DataClassName('RewriteOperationRevisionRow')
class RewriteOperationRevisions extends Table {
  @override
  String get tableName => 'rewrite_operation_revisions';

  TextColumn get rewriteOperationId => text()();
  IntColumn get revision => integer()();
  TextColumn get snapshotJson => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {rewriteOperationId, revision};
}

@DataClassName('RewriteEvidenceRow')
@TableIndex(
  name: 'idx_rewrite_evidence_operation',
  columns: {#rewriteOperationId},
)
class RewriteEvidenceRows extends Table {
  @override
  String get tableName => 'rewrite_evidence_rows';

  TextColumn get id => text()();
  TextColumn get rewriteOperationId => text()();
  TextColumn get evidenceJson => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CanonTransitionFactRefRow')
class CanonTransitionFactRefs extends Table {
  @override
  String get tableName => 'canon_transition_fact_refs';

  TextColumn get appliedCanonTransitionId => text()();
  TextColumn get characterKnowledgeFactId => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {
    appliedCanonTransitionId,
    characterKnowledgeFactId,
  };
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
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
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
  TextColumn get agentsJson => text().withDefault(const Constant('[]'))();
  TextColumn get expensiveApiConfigId =>
      text().withDefault(const Constant(''))();
  TextColumn get cheapApiConfigId => text().withDefault(const Constant(''))();
  TextColumn get cleanerApiConfigId => text().withDefault(const Constant(''))();
  TextColumn get ledgerApiConfigId => text().withDefault(const Constant(''))();
  IntColumn get maxFinalHistoryMessages =>
      integer().withDefault(const Constant(50))();
  TextColumn get agentEnabledJson => text().withDefault(const Constant('{}'))();
  TextColumn get executionMode =>
      text().withDefault(const Constant('legacy'))();
  TextColumn get runtimeSettingsJson =>
      text().withDefault(const Constant('{}'))();
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

@DataClassName('PresetFolderRow')
class PresetFolders extends Table {
  @override
  String get tableName => 'preset_folders';

  TextColumn get folderId => text()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {folderId};
}

@DataClassName('PresetFolderMemberRow')
@TableIndex(name: 'idx_pfm_folder', columns: {#folderId})
@TableIndex(name: 'idx_pfm_preset', columns: {#presetId})
class PresetFolderMembers extends Table {
  @override
  String get tableName => 'preset_folder_members';

  TextColumn get folderId => text()();
  TextColumn get presetId => text()();

  /// `normal` for rows in `presets`, `agentic` for rows in
  /// `studio_preset_rows`. The two id spaces are independent, so the kind is
  /// part of the key — without it an agentic preset could shadow a plain one
  /// that happens to share its id.
  TextColumn get kind => text().withDefault(const Constant('normal'))();
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

  // Composite PK: a preset can live in many folders, but cannot be duplicated
  // within one folder.
  @override
  Set<Column> get primaryKey => {folderId, presetId, kind};
}

@DataClassName('ApiConfigRow')
class ApiConfigs extends Table {
  @override
  String get tableName => 'api_configs';

  TextColumn get configId => text()();
  TextColumn get name => text()();
  TextColumn get providerId => text().withDefault(const Constant('openai'))();
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
  BoolColumn get excludeReasoningFromContextBudget =>
      boolean().withDefault(const Constant(false))();
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
  IntColumn get embeddingRequestsPerMinute =>
      integer().withDefault(const Constant(50))();
  TextColumn get cacheControlTtl => text().withDefault(const Constant('off'))();
  TextColumn get cacheBreakpointMode =>
      text().withDefault(const Constant('depth'))();
  TextColumn get sessionIdMode =>
      text().withDefault(const Constant('openrouter'))();
  IntColumn get firstChunkTimeoutMs =>
      integer().withDefault(const Constant(60000))();
  TextColumn get promptPostProcessing =>
      text().withDefault(const Constant('none'))();
  BoolColumn get useSystemInstruction =>
      boolean().withDefault(const Constant(true))();
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

/// Session-local evolved content for a source lorebook entry. Global lorebooks
/// remain the source for new sessions; branches explicitly copy this overlay.
@DataClassName('SessionLorebookEvolutionRow')
@TableIndex(
  name: 'idx_session_lorebook_evolution_session',
  columns: {#chatSessionId},
)
class SessionLorebookEvolutionRows extends Table {
  @override
  String get tableName => 'session_lorebook_evolution_rows';

  TextColumn get chatSessionId => text()();
  TextColumn get lorebookId => text()();
  TextColumn get entryId => text()();
  TextColumn get baseContent => text()();
  TextColumn get baseContentHash => text()();
  TextColumn get content => text()();
  TextColumn get contentHash => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {chatSessionId, lorebookId, entryId};
  @override
  List<String> get customConstraints => [
    "CHECK (chat_session_id <> '' AND lorebook_id <> '' AND entry_id <> '' "
        "AND base_content_hash <> '' AND content_hash <> '')",
  ];
}

/// Append-only points on a session's complete canon timeline. Each non-root
/// checkpoint is anchored to the accepted chat variation that caused it.
@DataClassName('SessionCanonCheckpointRow')
@TableIndex(
  name: 'idx_session_canon_checkpoint_sequence',
  columns: {#chatSessionId, #sequence},
  unique: true,
)
@TableIndex(
  name: 'idx_session_canon_checkpoint_anchor',
  columns: {#chatSessionId, #anchorMessageId},
)
@TableIndex(
  name: 'idx_session_canon_checkpoint_job',
  columns: {#rewriteJobId},
  unique: true,
)
class SessionCanonCheckpointRows extends Table {
  @override
  String get tableName => 'session_canon_checkpoint_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  IntColumn get sequence => integer()();
  TextColumn get parentCheckpointId => text().withDefault(const Constant(''))();
  TextColumn get characterId => text()();
  IntColumn get characterRevision => integer()();
  TextColumn get characterRevisionHash => text()();
  TextColumn get rewriteJobId => text().nullable()();
  TextColumn get anchorMessageId => text().withDefault(const Constant(''))();
  IntColumn get anchorSwipeId => integer().withDefault(const Constant(0))();
  IntColumn get anchorAgentSwipeId =>
      integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (id <> '' AND chat_session_id <> '' AND character_id <> '' "
        "AND character_revision >= 1 AND character_revision_hash <> '' "
        'AND sequence >= 0)',
    "CHECK ((sequence = 0 AND parent_checkpoint_id = '') OR "
        "(sequence > 0 AND parent_checkpoint_id <> '' "
        "AND anchor_message_id <> ''))",
  ];
}

/// Immutable lorebook changes attached to a complete session canon checkpoint.
@DataClassName('SessionLorebookRevisionRow')
@TableIndex(
  name: 'idx_session_lorebook_revision_target',
  columns: {#chatSessionId, #lorebookId, #entryId, #createdAt},
)
class SessionLorebookRevisionRows extends Table {
  @override
  String get tableName => 'session_lorebook_revision_rows';

  TextColumn get checkpointId => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get lorebookId => text()();
  TextColumn get entryId => text()();
  TextColumn get baseContentHash => text()();
  TextColumn get previousContentHash => text()();
  TextColumn get content => text()();
  TextColumn get contentHash => text()();
  TextColumn get rewriteOperationId => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {checkpointId, lorebookId, entryId};

  @override
  List<String> get customConstraints => [
    "CHECK (checkpoint_id <> '' AND chat_session_id <> '' "
        "AND lorebook_id <> '' AND entry_id <> '' "
        "AND base_content_hash <> '' AND previous_content_hash <> '' "
        "AND content_hash <> '' AND rewrite_operation_id <> '')",
  ];
}

/// Durable post-commit work for session-scoped lorebook embeddings.
@DataClassName('SessionLorebookEmbeddingJobRow')
@TableIndex(
  name: 'idx_session_lorebook_embedding_job_status',
  columns: {#status, #updatedAt},
)
@TableIndex(
  name: 'idx_session_lorebook_embedding_job_target',
  columns: {#chatSessionId, #lorebookId, #entryId},
)
class SessionLorebookEmbeddingJobRows extends Table {
  @override
  String get tableName => 'session_lorebook_embedding_job_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get checkpointId => text()();
  TextColumn get lorebookId => text()();
  TextColumn get entryId => text()();
  TextColumn get expectedContentHash => text()();
  TextColumn get operation => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (id <> '' AND chat_session_id <> '' AND checkpoint_id <> '' "
        "AND lorebook_id <> '' AND entry_id <> '' "
        "AND expected_content_hash <> '')",
    "CHECK (operation IN ('reindex', 'delete'))",
    "CHECK (status IN ('pending', 'running', 'succeeded', 'failed', "
        "'superseded'))",
    'CHECK (attempt_count >= 0)',
  ];
}

/// Immutable successful reconciliation evidence.  The JSON columns are
/// canonical codec payloads; their hashes are verified by the repository.
@DataClassName('LedgerReconciliationSuccessfulRunRow')
@TableIndex(
  name: 'idx_reconciliation_run_endpoint',
  columns: {
    #sessionId,
    #startMessageId,
    #startSwipeId,
    #startAgentSwipeId,
    #endMessageId,
    #endSwipeId,
    #endAgentSwipeId,
  },
)
@TableIndex(
  name: 'idx_reconciliation_run_content',
  columns: {#sessionId, #contentHash},
  unique: true,
)
@TableIndex(
  name: 'idx_reconciliation_run_chain',
  columns: {#sessionId, #chainHash},
  unique: true,
)
class LedgerReconciliationSuccessfulRuns extends Table {
  @override
  String get tableName => 'reconciliation_successful_runs';
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  IntColumn get ordinal => integer()();
  TextColumn get startMessageId => text()();
  IntColumn get startSwipeId => integer()();
  IntColumn get startAgentSwipeId => integer()();
  TextColumn get endMessageId => text()();
  IntColumn get endSwipeId => integer()();
  IntColumn get endAgentSwipeId => integer()();
  TextColumn get anchorsJson => text()();
  TextColumn get rangeHash => text()();
  TextColumn get acceptedManifestRefsJson => text()();
  TextColumn get effectiveCanonStamp => text()();
  IntColumn get effectiveCanonRevision => integer()();
  TextColumn get effectiveCanonHash => text()();
  TextColumn get canonicalResultJson => text()();
  TextColumn get contentHash => text()();
  TextColumn get predecessorChainHash => text()();
  TextColumn get chainHash => text()();
  IntColumn get contractVersion => integer()();
  TextColumn get opsAppliedJson => text()();
  IntColumn get createdAt => integer()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<Set<Column>> get uniqueKeys => [
    {sessionId, ordinal},
    {sessionId, contentHash},
    {sessionId, chainHash},
  ];
  @override
  List<String> get customConstraints => [
    'CHECK (ordinal > 0)',
    "CHECK (id <> '' AND session_id <> '' AND start_message_id <> '' "
        "AND end_message_id <> '' AND anchors_json <> '' AND range_hash <> '' "
        "AND accepted_manifest_refs_json <> '' AND effective_canon_stamp <> '' "
        "AND effective_canon_hash <> '' AND canonical_result_json <> '' "
        "AND content_hash <> '' AND chain_hash <> '' AND contract_version > 0)",
  ];
}

@DataClassName('LedgerReconciliationRunInvalidationRow')
class LedgerReconciliationRunInvalidations extends Table {
  @override
  String get tableName => 'reconciliation_run_invalidations';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text()();
  TextColumn get runId => text()();
  TextColumn get causeMessageId => text()();
  TextColumn get reason => text()();
  IntColumn get createdAt => integer()();
  @override
  List<Set<Column>> get uniqueKeys => [
    {sessionId, runId, causeMessageId, reason},
  ];
  @override
  List<String> get customConstraints => [
    "CHECK (session_id <> '' AND run_id <> '' AND cause_message_id <> '' AND reason <> '')",
  ];
}

/// Append-only cursor chain recording reconciliation runs consumed by an
/// automated card-evolution proposal.
@DataClassName('LedgerReconciliationCursorRow')
class LedgerReconciliationCursors extends Table {
  @override
  String get tableName => 'ledger_reconciliation_cursors';
  TextColumn get sessionId => text()();
  IntColumn get sequence => integer()();
  TextColumn get predecessorHash => text()();
  TextColumn get throughRunId => text()();
  IntColumn get throughRunOrdinal => integer()();
  TextColumn get throughRunChainHash => text()();
  TextColumn get cursorHash => text()();
  IntColumn get createdAt => integer()();
  @override
  Set<Column> get primaryKey => {sessionId, sequence};
  @override
  List<Set<Column>> get uniqueKeys => [
    {sessionId, cursorHash},
  ];
  @override
  List<String> get customConstraints => [
    "CHECK (sequence > 0 AND session_id <> '' "
        "AND ((sequence = 1 AND predecessor_hash = '') "
        "OR (sequence > 1 AND predecessor_hash <> '')) "
        "AND through_run_id <> '' AND through_run_ordinal > 0 "
        "AND through_run_chain_hash <> '' AND cursor_hash <> '')",
  ];
}

/// Expiring ownership for one automated evolution proposal attempt. Completed
/// rows remain as durable idempotency records; executable rows are `claimed`.
@DataClassName('CardEvolutionClaimRow')
@TableIndex(name: 'idx_card_evolution_claim_session', columns: {#sessionId})
@TableIndex(
  name: 'idx_card_evolution_claim_input',
  columns: {#sessionId, #inputHash},
  unique: true,
)
class CardEvolutionClaims extends Table {
  @override
  String get tableName => 'card_evolution_claims';
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get characterId => text()();
  TextColumn get ownerId => text()();
  TextColumn get status => text()();
  IntColumn get leaseExpiresAt => integer()();

  /// Legacy physical column name retained for v92 database compatibility.
  TextColumn get chatHistoryHash => text().named('first_run_id')();

  /// Legacy physical column name retained for v92 database compatibility.
  TextColumn get effectiveCanonIdentity => text().named('second_run_id')();
  TextColumn get predecessorCursorHash => text()();
  IntColumn get predecessorRunOrdinal => integer()();
  TextColumn get inputHash => text()();
  TextColumn get rewriteJobId => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get completedAt => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('claimed', 'completed'))",
    "CHECK (id <> '' AND session_id <> '' AND character_id <> '' "
        "AND owner_id <> '' AND first_run_id <> '' AND second_run_id <> '' "
        "AND input_hash <> '' AND predecessor_run_ordinal >= 0)",
  ];
}

/// Immutable output and exact selected-input provenance for an automated
/// proposal. The normal rewrite job remains the review/apply aggregate.
@DataClassName('CardEvolutionProposalRunRow')
class CardEvolutionProposalRuns extends Table {
  @override
  String get tableName => 'card_evolution_proposal_runs';
  TextColumn get id => text()();
  TextColumn get claimId => text()();
  TextColumn get sessionId => text()();
  TextColumn get characterId => text()();
  TextColumn get rewriteJobId => text()();

  /// Legacy physical column name retained for v92 database compatibility.
  TextColumn get chatHistoryHash => text().named('first_run_id')();

  /// Legacy physical column name retained for v92 database compatibility.
  TextColumn get effectiveCanonIdentity => text().named('second_run_id')();
  TextColumn get selectedInputJson => text()();
  TextColumn get inputHash => text()();
  TextColumn get modelOutput => text()();
  TextColumn get modelOutputHash => text()();
  TextColumn get operationSnapshotJson => text()();
  IntColumn get createdAt => integer()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<Set<Column>> get uniqueKeys => [
    {claimId},
    {rewriteJobId},
    {sessionId, inputHash},
  ];
  @override
  List<String> get customConstraints => [
    "CHECK (id <> '' AND claim_id <> '' AND session_id <> '' "
        "AND character_id <> '' AND rewrite_job_id <> '' "
        "AND first_run_id <> '' AND second_run_id <> '' "
        "AND selected_input_json <> '' AND input_hash <> '' "
        "AND model_output_hash <> '' AND operation_snapshot_json <> '')",
  ];
}

/// Rolling journal of Studio Ledger model exchanges kept for diagnosis.
///
/// A Ledger turn can silently spend a second model call: when the first
/// response fails to parse in a repairable way the service issues a repair
/// call. Nothing about that decision used to outlive the process, so a user
/// seeing two provider requests had no way to learn why. Each row therefore
/// records the raw response, the parser verdict that rejected it, whether a
/// repair call followed, and the final outcome.
///
/// The journal is intentionally bounded: only recent rows are retained and
/// stored payloads are truncated, because this is diagnostic state rather
/// than canon provenance.
@DataClassName('LedgerDebugRunRow')
class LedgerDebugRuns extends Table {
  @override
  String get tableName => 'ledger_debug_runs';
  TextColumn get id => text()();
  TextColumn get sessionId => text()();

  /// `normal` for the per-turn Ledger, `reconciliation` for range review.
  TextColumn get kind => text()();
  TextColumn get messageId => text().withDefault(const Constant(''))();
  IntColumn get swipeId => integer().withDefault(const Constant(0))();
  IntColumn get agentSwipeId => integer().withDefault(const Constant(0))();

  /// Terminal [LedgerRunResult.status] for the run.
  TextColumn get status => text()();
  TextColumn get model => text().withDefault(const Constant(''))();

  /// Parser failure class for the first response, e.g. `malformedJson`.
  TextColumn get parseFailure => text().withDefault(const Constant('none'))();

  /// Human-readable parser rejection text, when the response was rejected.
  TextColumn get rejectionReason => text().nullable()();

  /// Operations dropped by semantic validation, as a JSON array of strings.
  TextColumn get rejectedOpsJson => text().withDefault(const Constant('[]'))();
  BoolColumn get repairAttempted =>
      boolean().withDefault(const Constant(false))();

  /// Parser failure class after the repair response, when one was requested.
  TextColumn get repairFailure => text().nullable()();
  TextColumn get responseText => text().nullable()();
  TextColumn get repairResponseText => text().nullable()();
  TextColumn get attemptsJson => text().withDefault(const Constant('[]'))();
  TextColumn get error => text().nullable()();
  IntColumn get opsApplied => integer().withDefault(const Constant(0))();
  IntColumn get elapsedMs => integer().withDefault(const Constant(0))();
  IntColumn get promptChars => integer().withDefault(const Constant(0))();
  IntColumn get responseChars => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<String> get customConstraints => [
    "CHECK (id <> '' AND session_id <> '' "
        "AND kind IN ('normal', 'reconciliation') "
        "AND status <> '' AND attempts_json <> '' AND rejected_ops_json <> '')",
  ];
}

/// Bounded local history of sanitized requests observed immediately before
/// provider transport. This diagnostic data is neither canon nor sync state.
@DataClassName('LlmRequestCaptureRow')
@TableIndex(
  name: 'idx_llm_request_capture_session_stage_created',
  columns: {#sessionId, #stage, #createdAtMs},
)
@TableIndex(name: 'idx_llm_request_capture_created', columns: {#createdAtMs})
class LlmRequestCaptureRows extends Table {
  @override
  String get tableName => 'llm_request_capture_rows';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get sequence => integer()();
  IntColumn get createdAtMs => integer()();
  TextColumn get sessionId => text().nullable()();
  TextColumn get stage => text().nullable()();
  TextColumn get messageId => text().nullable()();
  TextColumn get pipelineRunId => text().nullable()();
  TextColumn get logicalCallId => text().nullable()();
  TextColumn get relatedArtifactId => text().nullable()();
  TextColumn get agentId => text().nullable()();
  IntColumn get stageOrdinal => integer().nullable()();
  IntColumn get attempt => integer().nullable()();
  TextColumn get protocol => text().nullable()();
  BoolColumn get truncated => boolean()();
  TextColumn get eventJson => text()();
}

/// Latest raw writer result retained per session and writer stage for Card
/// Rewriter debugging. This is intentionally replaceable diagnostic state,
/// unlike reviewable proposal provenance which remains immutable once
/// persisted.
///
/// The `selection` stage records writer runs that bailed before a model was
/// resolved (claim refused, prompt snapshot unavailable). It therefore has no
/// model name, which is why the model check is scoped to the model stages.
@DataClassName('CardEvolutionDebugRunRow')
class CardEvolutionDebugRuns extends Table {
  @override
  String get tableName => 'card_evolution_debug_runs';
  TextColumn get sessionId => text()();
  TextColumn get stage => text()();
  TextColumn get status => text()();
  TextColumn get model => text()();
  TextColumn get output => text().nullable()();
  TextColumn get attemptsJson => text()();
  IntColumn get updatedAt => integer()();
  @override
  Set<Column> get primaryKey => {sessionId, stage};
  @override
  List<String> get customConstraints => [
    "CHECK (session_id <> '' AND stage IN ('card', 'lorebook', 'selection') "
        "AND status <> '' AND attempts_json <> '' "
        "AND (stage = 'selection' OR model <> ''))",
  ];
}

/// Observation journal entries recording candidate durable character changes
/// surfaced by the observation pass. One active observation per semantic scope
/// per session; confirmations bump `repeatCount`/`lastConfirmedRun`. Promotion
/// flips `status` to `promoted`; expiry to `consumed` after a successful apply.
@DataClassName('CardEvolutionObservationRow')
@TableIndex(
  name: 'idx_card_evolution_observation_session',
  columns: {#sessionId, #status},
)
class CardEvolutionObservations extends Table {
  @override
  String get tableName => 'card_evolution_observations';
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get characterId => text()();
  IntColumn get runOrdinal => integer()();
  TextColumn get semanticScopeKey => text()();
  TextColumn get observedChange => text()();
  TextColumn get canonicalClaim => text().nullable()();
  TextColumn get evidenceMessageIds => text()();
  TextColumn get evidenceClustersJson =>
      text().withDefault(const Constant('[]'))();

  /// Exact, case-preserving Unicode Ledger keys (or exact injected lorebook
  /// identities) used to retrieve this row for a later bounded snapshot.
  TextColumn get retrievalKeysJson =>
      text().withDefault(const Constant('[]'))();

  /// `main_character_card` or `injected_lorebook_entry`.
  TextColumn get targetKind => text().nullable()();
  TextColumn get cardFieldPath => text().nullable()();
  TextColumn get lorebookEntryId => text().nullable()();
  RealColumn get confidence => real()();
  TextColumn get status => text()();
  IntColumn get firstSeenRun => integer()();
  IntColumn get repeatCount => integer().withDefault(const Constant(1))();
  IntColumn get lastConfirmedRun => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<Set<Column>> get uniqueKeys => [
    {sessionId, semanticScopeKey},
  ];
  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('active', 'promoted', 'expired', 'consumed'))",
    "CHECK (id <> '' AND session_id <> '' AND character_id <> '' "
        "AND semantic_scope_key <> '' AND observed_change <> '' "
        "AND evidence_message_ids <> '' AND confidence >= 0.0 "
        "AND confidence <= 1.0 AND first_seen_run > 0 AND repeat_count > 0)",
  ];
}

/// Durable completion/lease journal for the observation collector. A collector
/// run is tied to one immutable Ledger reconciliation range; valid empty model
/// responses are still recorded as completed so they are not replayed after a
/// restart.
@DataClassName('CardEvolutionCollectorRunRow')
@TableIndex(
  name: 'idx_card_evolution_collector_session_ordinal',
  columns: {#sessionId, #collectorOrdinal},
  unique: true,
)
@TableIndex(
  name: 'idx_card_evolution_collector_reconciliation',
  columns: {#sessionId, #reconciliationRunId},
  unique: true,
)
class CardEvolutionCollectorRuns extends Table {
  @override
  String get tableName => 'card_evolution_collector_runs';
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get characterId => text()();
  IntColumn get collectorOrdinal => integer()();
  TextColumn get reconciliationRunId => text()();
  IntColumn get reconciliationRunOrdinal => integer()();
  TextColumn get reconciliationChainHash => text()();
  TextColumn get rangeHash => text()();
  TextColumn get inputHash => text()();
  TextColumn get ownerId => text()();
  TextColumn get status => text()();
  IntColumn get leaseExpiresAt => integer()();
  TextColumn get modelOutputHash => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get completedAt => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<Set<Column>> get uniqueKeys => [
    {sessionId, collectorOrdinal},
    {sessionId, reconciliationRunId},
  ];
  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('claimed', 'completed'))",
    "CHECK (id <> '' AND session_id <> '' AND character_id <> '' "
        "AND collector_ordinal > 0 AND reconciliation_run_id <> '' "
        "AND reconciliation_run_ordinal > 0 AND reconciliation_chain_hash <> '' "
        "AND range_hash <> '' AND input_hash <> '' AND owner_id <> '')",
  ];
}

/// Immutable canonical lorebook-use manifest at one message variation anchor.
@DataClassName('LorebookUseManifestRow')
@TableIndex(
  name: 'idx_lorebook_use_manifest_session_anchor',
  columns: {#sessionId, #messageId, #swipeId, #agentSwipeId},
)
class LorebookUseManifests extends Table {
  @override
  String get tableName => 'lorebook_use_manifests';

  TextColumn get sessionId => text()();
  TextColumn get messageId => text()();
  IntColumn get swipeId => integer()();
  IntColumn get agentSwipeId => integer()();
  TextColumn get manifestJson => text().withDefault(const Constant('{}'))();
  TextColumn get manifestHash => text().withDefault(const Constant(''))();
  IntColumn get manifestSchemaVersion =>
      integer().withDefault(const Constant(1))();
  TextColumn get finalPromptHash => text().withDefault(const Constant(''))();
  TextColumn get presetSnapshotHash => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {sessionId, messageId, swipeId, agentSwipeId};
}

/// Immutable selected-entry evidence, namespaced within its manifest.
@DataClassName('LorebookUseManifestEntryRow')
class LorebookUseManifestEntries extends Table {
  @override
  String get tableName => 'lorebook_use_manifest_entries';

  TextColumn get sessionId => text()();
  TextColumn get messageId => text()();
  IntColumn get swipeId => integer()();
  IntColumn get agentSwipeId => integer()();
  TextColumn get lorebookId => text()();
  TextColumn get entryId => text()();
  IntColumn get entryOrder => integer()();
  TextColumn get evidenceJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {
    sessionId,
    messageId,
    swipeId,
    agentSwipeId,
    lorebookId,
    entryId,
    entryOrder,
  };

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (session_id, message_id, swipe_id, agent_swipe_id) '
        'REFERENCES lorebook_use_manifests '
        '(session_id, message_id, swipe_id, agent_swipe_id)',
  ];
}

/// Append-only acceptance events for a generated lorebook-use manifest.
///
/// A `variation` records the only authoritative acceptance: the next user
/// message accepted this exact assistant variation. `selection` is reserved
/// supplemental evidence and is deliberately not an eligibility signal.
@DataClassName('LorebookUseAcceptanceRecordRow')
@TableIndex(
  name: 'idx_lorebook_use_acceptance_session',
  columns: {#sessionId, #acceptedAt},
)
@TableIndex(
  name: 'idx_lorebook_use_acceptance_generation',
  columns: {#sessionId, #messageId, #swipeId, #agentSwipeId},
)
class LorebookUseAcceptanceRecords extends Table {
  @override
  String get tableName => 'lorebook_use_acceptance_records';

  TextColumn get acceptanceId => text()();
  TextColumn get sessionId => text()();
  TextColumn get messageId => text()();
  IntColumn get swipeId => integer()();
  IntColumn get agentSwipeId => integer()();
  TextColumn get acceptanceKind => text()();
  TextColumn get acceptedByUserMessageId => text().nullable()();
  TextColumn get selectedLorebookId => text().nullable()();
  TextColumn get selectedEntryId => text().nullable()();
  IntColumn get selectedEntryOrder => integer().nullable()();
  TextColumn get evidenceJson => text().withDefault(const Constant('{}'))();
  IntColumn get acceptedAt => integer()();

  @override
  Set<Column> get primaryKey => {acceptanceId};

  @override
  List<String> get customConstraints => [
    "CHECK (acceptance_kind IN ('variation', 'selection'))",
    "CHECK ((acceptance_kind = 'variation' "
        'AND accepted_by_user_message_id IS NOT NULL '
        'AND selected_lorebook_id IS NULL '
        'AND selected_entry_id IS NULL AND selected_entry_order IS NULL) OR '
        "(acceptance_kind = 'selection' AND selected_lorebook_id IS NOT NULL "
        'AND selected_entry_id IS NOT NULL AND selected_entry_order IS NOT NULL '
        'AND accepted_by_user_message_id IS NULL))',
    'FOREIGN KEY (session_id, message_id, swipe_id, agent_swipe_id) '
        'REFERENCES lorebook_use_manifests '
        '(session_id, message_id, swipe_id, agent_swipe_id)',
  ];
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
