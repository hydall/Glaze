part of '../tables.dart';

/// The agent library: one row per `AgentDefinition`, stored as JSON.
@DataClassName('AgentDefinitionRow')
class AgentDefinitionRows extends Table {
  @override
  String get tableName => 'agent_definitions';

  TextColumn get agentId => text()();
  TextColumn get dataJson => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {agentId};
}

/// Per-character and per-chat overrides of whether an agent runs. The most
/// specific row wins: chat, then character, then the agent's global flag.
@DataClassName('AgentBindingRow')
@TableIndex(name: 'idx_agent_bindings_target', columns: {#scope, #targetId})
class AgentBindingRows extends Table {
  @override
  String get tableName => 'agent_bindings';

  TextColumn get agentId => text()();

  /// `character` or `chat`.
  TextColumn get scope => text()();

  /// Character id or chat session id.
  TextColumn get targetId => text()();
  BoolColumn get enabled => boolean()();

  @override
  Set<Column> get primaryKey => {agentId, scope, targetId};
}

/// One agent run: what an agent was asked, what it answered, what it cost.
/// Display and debugging only — never a cache.
@DataClassName('AgentRunRow')
@TableIndex(name: 'idx_agent_runs_session', columns: {#sessionId, #createdAt})
class AgentRunRows extends Table {
  @override
  String get tableName => 'agent_runs';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text()();

  /// The reply the run belongs to: the target assistant message for post
  /// agents, the message before the reply for the others. May be empty.
  TextColumn get messageId => text().withDefault(const Constant(''))();
  TextColumn get agentId => text()();
  TextColumn get agentName => text().withDefault(const Constant(''))();
  TextColumn get phase => text()();
  TextColumn get resultType => text()();
  BoolColumn get ok => boolean().withDefault(const Constant(false))();
  TextColumn get error => text().nullable()();
  TextColumn get output => text().withDefault(const Constant(''))();

  /// The request as sent, JSON, for the run log's prompt view.
  TextColumn get promptJson => text().withDefault(const Constant('[]'))();
  IntColumn get promptTokens => integer().withDefault(const Constant(0))();
  IntColumn get completionTokens => integer().withDefault(const Constant(0))();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
}
