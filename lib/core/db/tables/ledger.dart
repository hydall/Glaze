part of '../tables.dart';

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

/// Immutable before/after state captured atomically with a reconciliation run.
@DataClassName('LedgerReconciliationEffectRow')
@TableIndex(
  name: 'idx_reconciliation_effect_session_created',
  columns: {#sessionId, #createdAt},
)
class LedgerReconciliationEffects extends Table {
  @override
  String get tableName => 'ledger_reconciliation_effects';

  TextColumn get runId => text()();
  TextColumn get sessionId => text()();
  TextColumn get beforeLedgerJson => text()();
  TextColumn get afterLedgerJson => text()();
  TextColumn get beforeKnowledgeJson => text()();
  TextColumn get afterKnowledgeJson => text()();
  TextColumn get actualEffectsJson => text()();
  TextColumn get beforeStateHash => text()();
  TextColumn get afterStateHash => text()();
  TextColumn get effectsHash => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {runId};

  @override
  List<String> get customConstraints => [
    "CHECK (run_id <> '' AND session_id <> '' AND before_ledger_json <> '' "
        "AND after_ledger_json <> '' AND before_knowledge_json <> '' "
        "AND after_knowledge_json <> '' AND actual_effects_json <> '' "
        "AND before_state_hash <> '' AND after_state_hash <> '' "
        "AND effects_hash <> '')",
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

/// Local-only mutex for reconciliation work. Rows are ephemeral and are not
/// included in backup or sync payloads.
@DataClassName('LedgerReconciliationLeaseRow')
class LedgerReconciliationLeases extends Table {
  @override
  String get tableName => 'ledger_reconciliation_leases';
  TextColumn get sessionId => text()();
  TextColumn get ownerId => text()();
  TextColumn get purpose => text()();
  IntColumn get leaseExpiresAt => integer()();
  IntColumn get acquiredAt => integer()();
  @override
  Set<Column> get primaryKey => {sessionId};
  @override
  List<String> get customConstraints => [
    "CHECK (session_id <> '' AND owner_id <> '')",
    "CHECK (purpose IN ('normal', 'manual', 'replacement'))",
    'CHECK (lease_expires_at > acquired_at)',
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
@TableIndex(name: 'idx_llm_request_capture_call', columns: {#callId})
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
  TextColumn get callId => text().nullable()();
  TextColumn get logicalCallId => text().nullable()();
  TextColumn get relatedArtifactId => text().nullable()();
  TextColumn get agentId => text().nullable()();
  IntColumn get stageOrdinal => integer().nullable()();
  IntColumn get attempt => integer().nullable()();
  TextColumn get protocol => text().nullable()();
  BoolColumn get truncated => boolean()();
  TextColumn get eventJson => text()();
}

/// Append-only transport and parser outcomes linked to request captures by
/// stable orchestration-owned call identity.
@DataClassName('LlmCallEventRow')
@TableIndex(
  name: 'idx_llm_call_event_session_created',
  columns: {#sessionId, #createdAtMs},
)
@TableIndex(
  name: 'idx_llm_call_event_call_attempt',
  columns: {#callId, #attempt},
)
class LlmCallEventRows extends Table {
  @override
  String get tableName => 'llm_call_event_rows';

  TextColumn get id => text()();
  IntColumn get createdAtMs => integer()();
  TextColumn get sessionId => text().nullable()();
  TextColumn get pipelineRunId => text()();
  TextColumn get callId => text()();
  TextColumn get parentCallId => text().nullable()();
  TextColumn get stage => text()();
  IntColumn get stageOrdinal => integer().nullable()();
  IntColumn get attempt => integer().nullable()();
  TextColumn get relatedArtifactId => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get status => text().nullable()();
  IntColumn get statusCode => integer().nullable()();
  TextColumn get responseText => text().nullable()();
  TextColumn get responseHash => text().nullable()();
  TextColumn get error => text().nullable()();
  TextColumn get parserName => text().nullable()();
  TextColumn get parserCode => text().nullable()();
  TextColumn get parserDetail => text().nullable()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  BoolColumn get truncated => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (id <> '' AND pipeline_run_id <> '' AND call_id <> '' "
        "AND stage <> '' AND kind IN ('transport_succeeded', "
        "'transport_failed', 'parser_accepted', 'parser_rejected', "
        "'result_selected', 'pipeline_completed', 'pipeline_failed'))",
  ];
}
