import 'dart:convert';

import 'package:drift/drift.dart';

import '../../application/sync_repo_interfaces.dart';
import '../../models/studio_config.dart';
import '../../models/studio_agent_codec.dart';
import '../../models/studio_preset_block_migration.dart';
import '../../models/studio_preset_codec.dart';
import '../app_db.dart';

class StudioPresetRepo implements SyncStudioPresetStore {
  final AppDatabase db;

  const StudioPresetRepo(this.db);

  static const _runtimeComputedBlockIds = {
    'runtime_envelope',
    'brief_usage_note',
    'hard_style_contract',
    'beauty_shard_contract',
  };

  @override
  Future<StudioPreset?> getById(String id) async {
    final row = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(id))).getSingleOrNull();
    if (row == null) return null;
    return _rowToModel(row);
  }

  Future<StudioPreset?> getDefault() => getById('default');

  /// Ensures the built-in `default` Studio preset exists and returns it.
  ///
  /// Fresh installs build the schema through `onCreate`, which (unlike the
  /// `onUpgrade` migration that seeds it) leaves `studio_preset_rows` empty.
  /// Without a seeded preset there is nothing to clone, so "Add Agentic
  /// Preset" would silently no-op. Idempotent — a no-op once the row exists.
  Future<StudioPreset> ensureDefaultSeeded() async {
    final existing = await getById('default');
    if (existing != null) return existing;
    final blocks = defaultStudioPresetSeedBlocks()
        .map(StudioPresetBlock.fromJson)
        .toList();
    final preset = StudioPreset(
      id: 'default',
      name: 'Default Studio Preset',
      blocks: blocks,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await upsert(preset);
    return preset;
  }

  @override
  Future<List<StudioPreset>> getAll() async {
    final rows = await db.select(db.studioPresetRows).get();
    return rows.map(_rowToModel).toList();
  }

  @override
  Future<void> put(StudioPreset preset) => upsert(preset);

  Future<void> upsert(StudioPreset preset) async {
    final normalized = _normalizePreset(preset);
    // Safety net: the editor has been observed persisting an empty block list
    // over a non-empty preset (root cause not yet identified — likely a
    // malformed row decode yielding `blocks: []` that the editor then saves).
    // Until the source is found, refuse to overwrite a non-empty preset with
    // an empty block list. Single-block deletion still works because the list
    // never crosses zero through normal editing; even if the user removes the
    // last block, the guard keeps the prior content, which is the safer
    // failure mode for an agentic preset.
    final existing = await (db.select(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(normalized.id))).getSingleOrNull();
    final storedBlocks = existing == null
        ? const <StudioPresetBlock>[]
        : _rowToModel(existing).blocks;
    final safeNormalized =
        (normalized.blocks.isEmpty && storedBlocks.isNotEmpty)
        ? normalized.copyWith(blocks: storedBlocks)
        : normalized;
    await db
        .into(db.studioPresetRows)
        .insertOnConflictUpdate(
          StudioPresetRowsCompanion.insert(
            presetId: safeNormalized.id,
            name: safeNormalized.name,
            blocksJson: Value(
              jsonEncode(safeNormalized.blocks.map((b) => b.toJson()).toList()),
            ),
            agentsJson: Value(
              StudioAgentCodec.encodeAgents(safeNormalized.agents),
            ),
            expensiveApiConfigId: Value(safeNormalized.expensiveApiConfigId),
            cheapApiConfigId: Value(safeNormalized.cheapApiConfigId),
            cleanerApiConfigId: Value(safeNormalized.cleanerApiConfigId),
            ledgerApiConfigId: Value(safeNormalized.ledgerApiConfigId),
            maxFinalHistoryMessages: Value(
              safeNormalized.maxFinalHistoryMessages,
            ),
            agentEnabledJson: Value(jsonEncode(safeNormalized.agentEnabled)),
            runtimeSettingsJson: Value(
              jsonEncode({
                ...StudioPresetCodec.encodeRuntime(safeNormalized.runtime),
                'agentBlockRestoreState': safeNormalized.agentBlockRestoreState,
                'controllerAlternativeBlockIds':
                    safeNormalized.controllerAlternativeBlockIds,
              }),
            ),
            updatedAt: Value(safeNormalized.updatedAt),
          ),
        );
  }

  @override
  Future<void> delete(String id) => deleteById(id);

  Future<void> deleteById(String id) async {
    await (db.delete(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals(id))).go();
  }

  StudioPreset _rowToModel(StudioPresetRow row) {
    // Decode the complete persisted representation at the codec boundary. In
    // particular, blocks must still be raw while the codec inspects the Ledger
    // control header; canonicalizing each block first can turn malformed
    // control data into an apparently valid opt-in.
    final persistedRuntime = _decodeJson(row.runtimeSettingsJson);
    final runtimeMap = persistedRuntime is Map
        ? Map<String, dynamic>.from(persistedRuntime)
        : const <String, dynamic>{};
    final decoded = StudioPresetCodec.decodePreset({
      'id': row.presetId,
      'name': row.name,
      'blocks': _decodeJson(row.blocksJson),
      'agents': _decodeJson(row.agentsJson),
      'expensiveApiConfigId': row.expensiveApiConfigId,
      'cheapApiConfigId': row.cheapApiConfigId,
      'cleanerApiConfigId': row.cleanerApiConfigId,
      'ledgerApiConfigId': row.ledgerApiConfigId,
      'maxFinalHistoryMessages': row.maxFinalHistoryMessages,
      'agentEnabled': _decodeJson(row.agentEnabledJson),
      'agentBlockRestoreState': runtimeMap['agentBlockRestoreState'],
      'controllerAlternativeBlockIds':
          runtimeMap['controllerAlternativeBlockIds'],
      'runtime': runtimeMap,
      'updatedAt': row.updatedAt,
    });
    return _normalizePreset(decoded.preset);
  }

  Object? _decodeJson(String source) {
    try {
      return jsonDecode(source);
    } on Object {
      return null;
    }
  }

  StudioPreset _normalizePreset(StudioPreset preset) {
    // Migrate legacy kind/section blocks to the mode/injectionPoint model
    // (STUDIO_UX_ANALYSIS §5) at the single repo choke point — covers reads,
    // writes, imports and the seeded default. Idempotent once migrated.
    final migrated = migrateStudioPresetBlocksToV2(preset.blocks);
    final blocks = migrated
        .where((block) => !_runtimeComputedBlockIds.contains(block.id))
        .toList();
    final agents = StudioAgentCodec.decodeAgentsJson(
      StudioAgentCodec.encodeAgents(preset.agents),
    );
    if (identical(migrated, preset.blocks) &&
        blocks.length == preset.blocks.length &&
        agents.length == preset.agents.length) {
      return preset;
    }
    return preset.copyWith(blocks: blocks, agents: agents);
  }
}
