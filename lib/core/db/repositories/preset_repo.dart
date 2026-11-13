import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../debug/perf_debug.dart';
import '../../models/preset.dart';
import '../../application/sync_repo_interfaces.dart';

class PresetRepo implements SyncPresetStore {
  final AppDatabase _db;
  PresetRepo(this._db);

  @override
  Future<List<Preset>> getAll() async {
    final rows = await _db.select(_db.presets).get();
    final decoded = await _decodeAll([for (final row in rows) row.dataJson]);
    for (int i = 0; i < rows.length; i++) {
      final repaired = decoded.repaired[i];
      if (repaired == null) continue;
      await _db
          .into(_db.presets)
          .insertOnConflictUpdate(
            PresetsCompanion(
              presetId: Value(decoded.presets[i].id),
              name: Value(decoded.presets[i].name),
              dataJson: Value(repaired),
            ),
          );
    }
    return decoded.presets;
  }

  /// A library this long (in characters of stored JSON) is decoded in another
  /// isolate. Below it, the decode is quicker than starting one.
  static const _offloadChars = 256 * 1024;

  /// The rows as models and, for each, the JSON to write back when the stored
  /// one does not round-trip (a repair), or null.
  ///
  /// Off this isolate when the library is big: ninety presets came to eight
  /// megabytes, decoded and encoded again here the first time a chat needed
  /// the active one — half a second with no frames, under the chat's loading
  /// spinner.
  static Future<_DecodedPresets> _decodeAll(List<String> raws) {
    final total = raws.fold(0, (n, raw) => n + raw.length);
    if (total < _offloadChars) return Future.value(_decodeAllHere(raws));
    return PerfDebug.slowAwait(
      'decode ${raws.length} presets off-thread (${PerfDebug.size(total)})',
      () => Isolate.run(() => _decodeAllHere(raws)),
    );
  }

  static _DecodedPresets _decodeAllHere(List<String> raws) {
    final presets = <Preset>[];
    final repaired = <String?>[];
    for (final raw in raws) {
      final preset = Preset.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      presets.add(preset);
      final again = jsonEncode(preset.toJson());
      repaired.add(again == raw ? null : again);
    }
    return (presets: presets, repaired: repaired);
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

typedef _DecodedPresets = ({List<Preset> presets, List<String?> repaired});
