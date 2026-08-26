part of '../tables.dart';

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
