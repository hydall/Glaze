import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/lorebook.dart';
import '../../application/sync_repo_interfaces.dart';

class LorebookRepo implements SyncLorebookStore {
  final AppDatabase _db;
  LorebookRepo(this._db);

  @override
  Future<List<Lorebook>> getAll() async {
    final rows = await _db.select(_db.lorebooks).get();
    return rows.map(_toModel).toList();
  }

  @override
  Future<Lorebook?> getById(String id) async {
    final row = await (_db.select(_db.lorebooks)
          ..where((t) => t.lorebookId.equals(id)))
        .getSingleOrNull();
    return row != null ? _toModel(row) : null;
  }

  @override
  Future<void> put(Lorebook lorebook) async {
    await _db.into(_db.lorebooks).insertOnConflictUpdate(_toCompanion(lorebook));
  }

  /// Writes [lorebooks] in a single batch — one reactive emission instead of
  /// one per book. Used by the mass character import, where every card can
  /// carry an embedded character book.
  Future<void> putAll(List<Lorebook> lorebooks) async {
    if (lorebooks.isEmpty) return;
    final companions = lorebooks.map(_toCompanion).toList();
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(_db.lorebooks, companions);
    });
  }

  @override
  Future<void> delete(String id) async {
    await (_db.delete(_db.lorebooks)..where((t) => t.lorebookId.equals(id))).go();
  }

  Future<List<Lorebook>> getByScopeAndTarget(String scope, String targetId) async {
    final rows = await (_db.select(_db.lorebooks)
          ..where((t) => t.activationScope.equals(scope) & t.activationTargetId.equals(targetId)))
        .get();
    return rows.map(_toModel).toList();
  }

  Future<void> putFromJson(Map<String, dynamic> json) async {
    final lorebook = Lorebook.fromJson(json);
    await put(lorebook);
  }

  Future<void> createEntryFromCatalog({
    required String characterId,
    required List<String> keys,
    required String content,
    Map<String, dynamic> extensions = const {},
    bool enabled = true,
    int insertionOrder = 0,
    bool caseSensitive = false,
    String name = '',
    int priority = 0,
    int id = 0,
    String comment = '',
    bool selective = false,
    List<String> secondaryKeys = const [],
    bool constant = false,
    int order = 0,
  }) async {
    final existing = await getById(characterId);
    final entries = existing != null ? List<LorebookEntry>.from(existing.entries) : <LorebookEntry>[];

    entries.add(LorebookEntry(
      id: id.toString(),
      comment: comment,
      enabled: enabled,
      constant: constant,
      keys: keys,
      secondaryKeys: secondaryKeys,
      content: content,
      order: insertionOrder > 0 ? insertionOrder : order,
      caseSensitive: caseSensitive,
    ));

    final lorebook = Lorebook(
      id: characterId,
      name: name.isNotEmpty ? name : 'Lorebook for $characterId',
      enabled: false,
      activationScope: 'character',
      activationTargetId: characterId,
      entries: entries,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await put(lorebook);
  }

  Lorebook _toModel(LorebookRow r) => Lorebook(
        id: r.lorebookId,
        name: r.name,
        enabled: r.enabled,
        activationScope: r.activationScope,
        activationTargetId: r.activationTargetId,
        entries: _parseEntries(r.entriesJson),
        settings: _parseSettings(r.settingsJson),
        description: r.description,
        updatedAt: r.updatedAt,
      );

  LorebooksCompanion _toCompanion(Lorebook m) => LorebooksCompanion(
        lorebookId: Value(m.id),
        name: Value(m.name),
        enabled: Value(m.enabled),
        activationScope: Value(m.activationScope),
        activationTargetId: Value(m.activationTargetId),
        entriesJson: Value(jsonEncode(m.entries.map((e) => e.toJson()).toList())),
        settingsJson: Value(m.settings != null ? jsonEncode(m.settings!.toJson()) : ''),
        description: Value(m.description),
        updatedAt: Value(m.updatedAt),
      );

  List<LorebookEntry> _parseEntries(String json) {
    try {
      final list = jsonDecode(json) as List;
      return list.map((e) => LorebookEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  LorebookSettings? _parseSettings(String json) {
    if (json.isEmpty) return null;
    try {
      return LorebookSettings.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
