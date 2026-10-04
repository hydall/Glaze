import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/preset.dart';
import '../../application/sync_repo_interfaces.dart';

class PresetRepo implements SyncPresetStore {
  final AppDatabase _db;
  PresetRepo(this._db);

  @override
  Future<List<Preset>> getAll() async {
    final rows = await _db.select(_db.presets).get();
    final presets = rows.map(_toModel).toList();
    for (int i = 0; i < presets.length; i++) {
      final original = rows[i].dataJson;
      final repaired = jsonEncode(presets[i].toJson());
      if (original != repaired) {
        await _db
            .into(_db.presets)
            .insertOnConflictUpdate(
              PresetsCompanion(
                presetId: Value(presets[i].id),
                name: Value(presets[i].name),
                dataJson: Value(repaired),
              ),
            );
      }
    }
    return presets;
  }

  @override
  Future<Preset?> getById(String id) async {
    final row = await (_db.select(
      _db.presets,
    )..where((t) => t.presetId.equals(id))).getSingleOrNull();
    return row != null ? _toModel(row) : null;
  }

  @override
  Future<void> put(Preset preset) async {
    await _db.into(_db.presets).insertOnConflictUpdate(_toCompanion(preset));
  }

  @override
  Future<void> delete(String id) async {
    await (_db.delete(_db.presets)..where((t) => t.presetId.equals(id))).go();
  }

  Future<void> putFromMap(Map<String, dynamic> m) async {
    final preset = Preset.fromJson(m);
    await put(preset);
  }

  Preset _toModel(PresetRow c) =>
      Preset.fromJson(jsonDecode(c.dataJson) as Map<String, dynamic>);

  PresetsCompanion _toCompanion(Preset m) => PresetsCompanion(
    presetId: Value(m.id),
    name: Value(m.name),
    dataJson: Value(jsonEncode(m.toJson())),
  );
}
