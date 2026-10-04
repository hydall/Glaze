part of '../tables.dart';

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
