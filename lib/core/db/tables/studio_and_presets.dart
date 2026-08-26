part of '../tables.dart';

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
