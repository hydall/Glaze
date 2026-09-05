import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/persona.dart';
import '../../application/sync_repo_interfaces.dart';

class PersonaRepo implements SyncPersonaStore {
  final AppDatabase _db;
  PersonaRepo(this._db);
  Future<void>? _ensureDisplayNameColumnFuture;

  Future<void> _ensureDisplayNameColumn() {
    return _ensureDisplayNameColumnFuture ??= () async {
      final cols = await _db
          .customSelect('PRAGMA table_info("personas")')
          .get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('display_name')) {
        await _db.customStatement(
          'ALTER TABLE personas ADD COLUMN display_name TEXT',
        );
      }
    }();
  }

  @override
  Future<List<Persona>> getAll() async {
    await _ensureDisplayNameColumn();
    final rows = await _db.customSelect('''
      SELECT persona_id, name, display_name, prompt, avatar_path, created_at
      FROM personas
      ORDER BY created_at DESC
      ''').get();
    return rows.map(_toModel).toList();
  }

  @override
  Future<Persona?> getById(String id) async {
    await _ensureDisplayNameColumn();
    final row = await _db
        .customSelect(
          '''
      SELECT persona_id, name, display_name, prompt, avatar_path, created_at
      FROM personas
      WHERE persona_id = ?
      LIMIT 1
      ''',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    return row != null ? _toModel(row) : null;
  }

  @override
  Future<void> put(Persona persona) async {
    await _ensureDisplayNameColumn();
    await _db.customStatement(
      '''
      INSERT INTO personas (persona_id, name, display_name, prompt, avatar_path, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(persona_id) DO UPDATE SET
        name = excluded.name,
        display_name = excluded.display_name,
        prompt = excluded.prompt,
        avatar_path = excluded.avatar_path,
        created_at = excluded.created_at
      ''',
      [
        persona.id,
        persona.name,
        persona.displayName,
        persona.prompt,
        persona.avatarPath,
        persona.createdAt,
      ],
    );
  }

  @override
  Future<void> delete(String id) async {
    await (_db.delete(_db.personas)..where((t) => t.personaId.equals(id))).go();
  }

  Persona _toModel(QueryRow row) => Persona(
    id: row.read<String>('persona_id'),
    name: row.read<String>('name'),
    displayName: row.readNullable<String>('display_name'),
    prompt: row.readNullable<String>('prompt'),
    avatarPath: row.readNullable<String>('avatar_path'),
    createdAt: row.read<int>('created_at'),
  );
}
