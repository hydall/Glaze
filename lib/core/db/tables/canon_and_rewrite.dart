part of '../tables.dart';

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
  TextColumn get selectedInputJson => text().nullable()();
  TextColumn get writerOptionsJson =>
      text().withDefault(const Constant('{}'))();
  TextColumn get rewriteJobId => text().nullable()();
  TextColumn get failureCode => text().nullable()();
  TextColumn get failureDetail => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get completedAt => integer().nullable()();
  IntColumn get failedAt => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('claimed', 'failed', 'completed'))",
    "CHECK (id <> '' AND session_id <> '' AND character_id <> '' "
        "AND owner_id <> '' AND first_run_id <> '' AND second_run_id <> '' "
        "AND input_hash <> '' AND predecessor_run_ordinal >= 0)",
  ];
}

/// Durable checkpoints for each logical model call in an automatic Card
/// Rewriter claim. Completed rows form the reusable prefix after a restart.
@DataClassName('CardEvolutionWriterCallRow')
@TableIndex(
  name: 'idx_card_evolution_writer_call_session_updated',
  columns: {#sessionId, #updatedAt},
)
class CardEvolutionWriterCalls extends Table {
  @override
  String get tableName => 'card_evolution_writer_calls';
  TextColumn get id => text()();
  TextColumn get claimId => text()();
  TextColumn get sessionId => text()();
  IntColumn get ordinal => integer()();
  TextColumn get stage => text()();
  IntColumn get stageOrdinal => integer()();
  TextColumn get status => text()();
  TextColumn get prompt => text()();
  TextColumn get promptHash => text()();
  TextColumn get responseText => text().nullable()();
  TextColumn get responseHash => text().nullable()();
  TextColumn get resultJson => text().nullable()();
  TextColumn get source => text().nullable()();
  TextColumn get lastCallId => text().nullable()();
  TextColumn get parentCallId => text().nullable()();
  TextColumn get parserCode => text().nullable()();
  TextColumn get parserDetail => text().nullable()();
  TextColumn get failureCode => text().nullable()();
  TextColumn get failureDetail => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get completedAt => integer().nullable()();
  IntColumn get failedAt => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<Set<Column>> get uniqueKeys => [
    {claimId, ordinal},
    {claimId, stage, stageOrdinal},
  ];
  @override
  List<String> get customConstraints => [
    "CHECK (stage IN ('history_consolidation', 'card_writer', "
        "'card_repair', 'lorebook_writer'))",
    "CHECK (status IN ('prepared', 'failed', 'completed'))",
    "CHECK (id <> '' AND claim_id <> '' AND session_id <> '' "
        "AND ordinal > 0 AND stage_ordinal > 0 AND prompt <> '' "
        "AND prompt_hash <> '')",
    "CHECK (status <> 'completed' OR "
        "(response_text IS NOT NULL AND response_hash IS NOT NULL))",
    "CHECK (status <> 'failed' OR failure_code IS NOT NULL)",
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
  TextColumn get lastCallId => text().nullable()();
  TextColumn get failureCode => text().nullable()();
  TextColumn get failureDetail => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get completedAt => integer().nullable()();
  IntColumn get failedAt => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<Set<Column>> get uniqueKeys => [
    {sessionId, collectorOrdinal},
    {sessionId, reconciliationRunId},
  ];
  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('claimed', 'failed', 'completed'))",
    "CHECK (id <> '' AND session_id <> '' AND character_id <> '' "
        "AND collector_ordinal > 0 AND reconciliation_run_id <> '' "
        "AND reconciliation_run_ordinal > 0 AND reconciliation_chain_hash <> '' "
        "AND range_hash <> '' AND input_hash <> '' AND owner_id <> '')",
  ];
}
