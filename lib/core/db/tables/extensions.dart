part of '../tables.dart';

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
