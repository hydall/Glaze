import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../tables.dart';
import '../../../features/extensions/models/extension_preset.dart';

part 'extension_presets_repository.g.dart';

@DriftAccessor(tables: [ExtensionPresets])
class ExtensionPresetsRepository extends DatabaseAccessor<AppDatabase>
    with _$ExtensionPresetsRepositoryMixin {
  ExtensionPresetsRepository(super.db);

  Future<void> insert(ExtensionPreset preset) async {
    await into(extensionPresets).insert(ExtensionPresetsCompanion.insert(
      id: preset.id,
      name: preset.name,
      configJson: jsonEncode(preset.toJson()),
      createdAt: Value(preset.createdAt),
    ));
  }

  Future<List<ExtensionPreset>> getAll() async {
    final rows = await (select(extensionPresets)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();

    final result = <ExtensionPreset>[];
    for (final row in rows) {
      try {
        final json = jsonDecode(row.configJson) as Map<String, dynamic>;
        result.add(ExtensionPreset.fromJson({
          ...json,
          'id': row.id,
          'name': row.name,
          'createdAt': row.createdAt,
        }));
      } catch (_) {
        // Skip malformed rows silently — corrupt configJson shouldn't
        // block the entire list.
        continue;
      }
    }
    return result;
  }

  Future<ExtensionPreset?> getById(String id) async {
    final row = await (select(extensionPresets)
          ..where((tbl) => tbl.id.equals(id)))
        .getSingleOrNull();

    if (row == null) return null;

    final json = jsonDecode(row.configJson) as Map<String, dynamic>;
    return ExtensionPreset.fromJson({
      ...json,
      'id': row.id,
      'name': row.name,
      'createdAt': row.createdAt,
    });
  }

  Future<void> updatePreset(ExtensionPreset preset) async {
    await (update(extensionPresets)
          ..where((tbl) => tbl.id.equals(preset.id)))
        .write(ExtensionPresetsCompanion(
      name: Value(preset.name),
      configJson: Value(jsonEncode(preset.toJson())),
    ));
  }

  Future<void> deletePreset(String id) async {
    await (delete(extensionPresets)..where((tbl) => tbl.id.equals(id))).go();
  }
}
