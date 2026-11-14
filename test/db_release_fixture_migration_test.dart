@Tags(['db-migration'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Databases written by released builds, kept under `test/fixtures/db/`.
///
/// Each fixture was produced by the released code itself (a worktree of the
/// release tag), so it carries that release's real schema rather than the
/// current schema with a table dropped. Each has its generator alongside it
/// (`test/fixtures/db/generate_*.dart`); add one per stable release.
const _releaseFixtures = {
  'v0.7.0 (schema v79)': 'test/fixtures/db/glaze_v079_0.7.0.db',
};

/// Differences from a fresh install that are known and harmless.
const _acceptedDifferences = {
  // `PersonaRepo` adds `display_name` at runtime rather than through a
  // migration, so the column exists once the repo has run (it ran in 0.7.0
  // while the fixture was written) and is absent from a fresh `createAll`.
  'table personas',
  // v123 raised the stored values from 30 to 50 but could not change the
  // column DEFAULT without a rebuild. `StudioPresetRepo` always writes the
  // value explicitly, so the DEFAULT is never used.
  'table studio_preset_rows',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final MapEntry(key: release, value: path) in _releaseFixtures.entries) {
    group(release, () {
      late File copy;
      late AppDatabase upgraded;

      setUp(() async {
        copy = File(
          '${Directory.systemTemp.path}/glaze_release_fixture_'
          '${DateTime.now().microsecondsSinceEpoch}.db',
        );
        await File(path).copy(copy.path);
        upgraded = AppDatabase.forTesting(NativeDatabase(copy));
      });

      tearDown(() async {
        await upgraded.close();
        if (copy.existsSync()) await copy.delete();
      });

      test('upgrades to the current schema version', () async {
        final version = await upgraded
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.read<int>('user_version'), upgraded.schemaVersion);
      });

      test('ends with the same schema as a fresh install', () async {
        final fresh = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(fresh.close);

        final expected = await _schemaOf(fresh);
        final actual = await _schemaOf(upgraded);
        final differences = [
          for (final name in expected.keys)
            if (!actual.containsKey(name))
              'missing $name'
            else if ('${actual[name]}' != '${expected[name]}' &&
                !_acceptedDifferences.contains(name))
              'differs $name\n  fresh:    ${expected[name]}\n'
                  '  upgraded: ${actual[name]}',
          for (final name in actual.keys)
            if (!expected.containsKey(name)) 'extra $name',
        ];
        expect(differences, isEmpty, reason: differences.join('\n'));
      });

      test('keeps the user data it started with', () async {
        Future<int> count(String table) async => (await upgraded
                .customSelect('SELECT COUNT(*) AS c FROM $table')
                .getSingle())
            .read<int>('c');

        expect(await count('characters'), 3);
        expect(await count('chat_sessions'), 2);
        expect(await count('lorebooks'), 2);
        expect(await count('api_configs'), 2);
        expect(await count('presets'), greaterThanOrEqualTo(1));
        expect(await count('personas'), 1);
        expect(await count('tracker_snapshots'), 1);
        expect(await count('character_knowledge_fact_rows'), 1);
      });

      test('passes the SQLite integrity and foreign key checks', () async {
        final integrity = await upgraded
            .customSelect('PRAGMA integrity_check')
            .get();
        expect(integrity.map((r) => r.data.values.single), ['ok']);
        final foreignKeys = await upgraded
            .customSelect('PRAGMA foreign_key_check')
            .get();
        expect(foreignKeys, isEmpty);
      });
    });
  }
}

/// A comparable description of every table, index and trigger.
///
/// Column order is ignored: `ALTER TABLE ... ADD COLUMN` appends columns, so
/// an upgraded table legitimately lists them in a different order than a
/// fresh `CREATE TABLE`, and Drift reads columns by name.
Future<Map<String, Object>> _schemaOf(AppDatabase db) async {
  final schema = <String, Object>{};
  final objects = await db
      .customSelect(
        'SELECT type, name, tbl_name, sql FROM sqlite_master '
        "WHERE name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  for (final object in objects) {
    final type = object.read<String>('type');
    final name = object.read<String>('name');
    switch (type) {
      case 'table':
        final columns = await db
            .customSelect("PRAGMA table_info('$name')")
            .get();
        schema['table $name'] = (columns.map(
          (c) =>
              '${c.read<String>('name')} ${c.read<String>('type')} '
              'notnull=${c.read<int>('notnull')} '
              'default=${c.readNullable<String>('dflt_value')} '
              'pk=${c.read<int>('pk')}',
        ).toList()..sort());
        schema['checks $name'] = _checks(object.read<String>('sql'));
      case 'index':
        final sql = object.readNullable<String>('sql');
        schema['index $name'] = sql == null
            ? 'auto on ${object.read<String>('tbl_name')}'
            : _normalize(sql);
      case 'trigger':
        schema['trigger $name'] = _normalize(object.read<String>('sql'));
      default:
        schema['$type $name'] = _normalize(object.read<String>('sql'));
    }
  }
  return schema;
}

/// The CHECK constraints of a `CREATE TABLE` statement, order-insensitive.
List<String> _checks(String createTable) {
  final checks = <String>[];
  final source = _normalize(createTable);
  var start = source.indexOf('CHECK');
  while (start != -1) {
    final open = source.indexOf('(', start);
    var depth = 0;
    var end = open;
    for (; end < source.length; end++) {
      if (source[end] == '(') depth++;
      if (source[end] == ')' && --depth == 0) break;
    }
    checks.add(source.substring(open, end + 1));
    start = source.indexOf('CHECK', end);
  }
  return checks..sort();
}

String _normalize(String sql) => sql
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('"', '')
    .replaceAllMapped(RegExp(r'\s*([(),])\s*'), (m) => m[1]!)
    .replaceAll('IF NOT EXISTS ', '')
    .trim();
