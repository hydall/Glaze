import 'dart:convert';

import 'package:drift/drift.dart';

import '../../application/sync_repo_interfaces.dart';
import '../../models/studio_config.dart';
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

  @override
  Future<List<StudioPreset>> getAll() async {
    final rows = await db.select(db.studioPresetRows).get();
    return rows.map(_rowToModel).toList();
  }

  @override
  Future<void> put(StudioPreset preset) => upsert(preset);

  Future<void> upsert(StudioPreset preset) async {
    final normalized = _normalizePreset(preset);
    await db
        .into(db.studioPresetRows)
        .insertOnConflictUpdate(
          StudioPresetRowsCompanion.insert(
            presetId: normalized.id,
            name: normalized.name,
            blocksJson: Value(
              jsonEncode(normalized.blocks.map((b) => b.toJson()).toList()),
            ),
            agentEnabledJson: Value(jsonEncode(normalized.agentEnabled)),
            executionMode: Value(normalized.executionMode.wireName),
            updatedAt: Value(normalized.updatedAt),
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
    List<StudioPresetBlock> blocks;
    try {
      final list = jsonDecode(row.blocksJson) as List<dynamic>;
      blocks = list
          .map((e) => StudioPresetBlock.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      blocks = [];
    }
    Map<String, bool> agentEnabled;
    try {
      agentEnabled = (jsonDecode(row.agentEnabledJson) as Map<String, dynamic>)
          .map((key, value) => MapEntry(key, value == true));
    } catch (_) {
      agentEnabled = const {};
    }
    return _normalizePreset(
      StudioPreset(
        id: row.presetId,
        name: row.name,
        blocks: blocks,
        agentEnabled: agentEnabled,
        executionMode: StudioExecutionMode.fromWireName(row.executionMode),
        updatedAt: row.updatedAt,
      ),
    );
  }

  StudioPreset _normalizePreset(StudioPreset preset) {
    final blocks = preset.blocks
        .where((block) => !_runtimeComputedBlockIds.contains(block.id))
        .toList();
    if (blocks.length == preset.blocks.length) return preset;
    return preset.copyWith(blocks: blocks);
  }
}
