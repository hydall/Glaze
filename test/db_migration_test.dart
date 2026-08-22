import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/js_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

class _TestImageStorage extends ImageStorageService {
  _TestImageStorage()
    : super(Directory.systemTemp.createTempSync('glaze_test_img_').path);

  @override
  Future<String> saveAvatar(String characterId, Uint8List imageBytes) async {
    return '/fake/avatars/$characterId.png';
  }

  @override
  Future<String?> saveThumbnail(
    String characterId,
    Uint8List imageBytes,
  ) async {
    return '/fake/thumbnails/$characterId.jpg';
  }
}

void main() {
  group('Backup importer schema safety', () {
    late AppDatabase db;
    late ImageStorageService imageStorage;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = _testDb();
      imageStorage = _TestImageStorage();
    });

    tearDown(() async {
      await db.close();
    });

    test('calling import() twice does not crash on duplicate column', () async {
      final importer = JsBackupImporter(db, imageStorage);
      final data = _minimalBackup();

      await importer.import(data, onProgress: (_) {});

      await importer.import(data, onProgress: (_) {});
    });

    test('created_at column exists after import', () async {
      final importer = JsBackupImporter(db, imageStorage);
      await importer.import(_minimalBackup(), onProgress: (_) {});

      final cols = await db
          .customSelect("PRAGMA table_info('characters')")
          .get();
      final names = cols.map((c) => c.read<String>('name')).toSet();

      expect(names, contains('created_at'));
      expect(names, contains('macro_name'));
      expect(names, contains('picks_hash'));
    });

    test('current schema version after import', () async {
      final importer = JsBackupImporter(db, imageStorage);
      await importer.import(_minimalBackup(), onProgress: (_) {});

      final result = await db.customSelect('PRAGMA user_version').get();
      final version = result.first.read<int>('user_version');

      // user_version matches the Drift schema version (app_db.dart schemaVersion).
      // Update this constant whenever a new migration step is added.
      expect(version, 122);
    });

    test(
      'v100 adds Studio preset runtime settings with an empty default',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_studio_runtime_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'ALTER TABLE studio_preset_rows DROP COLUMN runtime_settings_json',
        );
        await seeded.customStatement('PRAGMA user_version = 99');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        await upgraded.customSelect('SELECT 1').get();

        final columns = await upgraded
            .customSelect("PRAGMA table_info('studio_preset_rows')")
            .get();
        final runtimeColumn = columns.singleWhere(
          (row) => row.read<String>('name') == 'runtime_settings_json',
        );
        expect(runtimeColumn.read<int>('notnull'), 1);
        expect(runtimeColumn.read<String>('dflt_value'), "'{}'");
        final row = await upgraded
            .customSelect(
              "SELECT runtime_settings_json FROM studio_preset_rows WHERE preset_id = 'default'",
            )
            .getSingle();
        expect(row.read<String>('runtime_settings_json'), '{}');
      },
    );

    test('v101 retires Studio profiles without losing session state', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_studio_sessions_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        "ALTER TABLE studio_config_rows ADD COLUMN profile_id TEXT NOT NULL DEFAULT ''",
      );
      await seeded.customStatement(
        "ALTER TABLE studio_config_rows ADD COLUMN profile_name TEXT NOT NULL DEFAULT ''",
      );
      await seeded.customStatement(
        "ALTER TABLE studio_config_rows ADD COLUMN broadcast_blocks_json TEXT NOT NULL DEFAULT '[]'",
      );
      await seeded.customStatement(
        "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES ('session', 'char', 0, '[]')",
      );
      await seeded.customStatement(
        'INSERT INTO studio_config_rows '
        '(session_id, profile_id, profile_name, enabled, '
        'broadcast_blocks_json, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?)',
        [
          'session',
          'profile',
          'Binding',
          1,
          '[]',
          10,
          20,
          'profile',
          'profile',
          'Old Profile',
          1,
          '["legacy rule"]',
          5,
          30,
        ],
      );
      await seeded.customStatement('PRAGMA user_version = 100');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(upgraded.close);
      final configRows = await upgraded
          .customSelect('SELECT * FROM studio_config_rows')
          .get();
      final columns = await upgraded
          .customSelect("PRAGMA table_info('studio_config_rows')")
          .get();
      final names = columns.map((row) => row.read<String>('name')).toSet();
      final preset = await upgraded
          .customSelect(
            "SELECT runtime_settings_json FROM studio_preset_rows WHERE preset_id = 'default'",
          )
          .getSingle();
      final runtime =
          jsonDecode(preset.read<String>('runtime_settings_json'))
              as Map<String, dynamic>;

      expect(configRows, hasLength(1));
      expect(configRows.single.read<String>('session_id'), 'session');
      expect(configRows.single.read<bool>('enabled'), isTrue);
      expect(names, {'session_id', 'enabled', 'created_at', 'updated_at'});
      expect(runtime['broadcastBlocks'], ['legacy rule']);
    });

    test(
      'upgrade from v15 with macro_name already present does not crash',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_test_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement('PRAGMA user_version = 15');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        // Ensure the db handle is released even if an expectation below
        // fails — otherwise Windows cannot delete the temp file in tearDown.
        addTearDown(() async => upgraded.close());
        await upgraded.customSelect('SELECT 1').get();

        final cols = await upgraded
            .customSelect("PRAGMA table_info('characters')")
            .get();
        final names = cols.map((c) => c.read<String>('name')).toSet();
        expect(names, contains('macro_name'));

        final version = await upgraded
            .customSelect('PRAGMA user_version')
            .get();
        expect(version.first.read<int>('user_version'), 122);
        expect(names, contains('variant_group_id'));
        expect(names, contains('hidden'));
      },
    );

    test('v67 upgrade tolerates a v66 schema without studio_preset_id', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_studio_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('PRAGMA user_version = 66');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test(
      'v97 canonicalizes valid Studio agents and preserves malformed rows',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_studio_agents_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN profile_id '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN profile_name '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN broadcast_blocks_json '
          "TEXT NOT NULL DEFAULT '[]'",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN agents_json '
          "TEXT NOT NULL DEFAULT '[]'",
        );
        final legacy = jsonEncode([
          {
            'id': 'agent_session_continuity_123',
            'name': 'Continuity Controller',
            'sourceBlockNames': 'legacy',
            'temperature': 0.65,
          },
          {'id': 'unknown', 'name': 'Unknown', 'enabled': true},
        ]);
        await seeded.customStatement(
          'INSERT INTO studio_config_rows '
          '(session_id, agents_json, updated_at) VALUES (?, ?, ?)',
          ['valid', legacy, 10],
        );
        await seeded.customStatement(
          'INSERT INTO studio_config_rows '
          '(session_id, agents_json, updated_at) VALUES (?, ?, ?)',
          ['malformed', '{bad json', 20],
        );
        await seeded.customStatement('PRAGMA user_version = 96');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        final rows = await upgraded
            .customSelect(
              'SELECT preset_id, agents_json, updated_at '
              'FROM studio_preset_rows WHERE preset_id = ? OR preset_id LIKE ? '
              'ORDER BY preset_id',
              variables: [
                const Variable<String>('default'),
                const Variable<String>('migrated_%'),
              ],
            )
            .get();
        final valid = rows.singleWhere(
          (row) => row.read<String>('preset_id') == 'default',
        );
        final malformed = rows.singleWhere(
          (row) => row.read<String>('preset_id').startsWith('migrated_'),
        );
        final agents = jsonDecode(valid.read<String>('agents_json')) as List;

        expect(malformed.read<String>('agents_json'), '{bad json');
        expect(malformed.read<int>('updated_at'), 20);
        expect(agents[0]['controllerId'], 'continuity');
        expect(agents[0], isNot(contains('sourceBlockNames')));
        expect(agents[0]['temperature'], 0.65);
        expect(agents[1]['controllerId'], isEmpty);
        expect(agents[1]['enabled'], isFalse);
        expect(valid.read<int>('updated_at'), greaterThan(10));
      },
    );

    test(
      'v98 migrates the legacy Studio API fallback and drops dead columns',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_studio_api_slots_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN final_preset_id '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN run_api_config_id '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN run_model_override '
          "TEXT NOT NULL DEFAULT ''",
        );
        for (final column in const [
          'agents_json TEXT NOT NULL DEFAULT \'[]\'',
          'expensive_api_config_id TEXT NOT NULL DEFAULT \'\'',
          'cheap_api_config_id TEXT NOT NULL DEFAULT \'\'',
          'cleaner_api_config_id TEXT NOT NULL DEFAULT \'\'',
          'max_final_history_messages INTEGER NOT NULL DEFAULT 30',
        ]) {
          await seeded.customStatement(
            'ALTER TABLE studio_config_rows ADD COLUMN $column',
          );
        }
        await seeded.customStatement(
          'INSERT INTO studio_config_rows '
          '(session_id, run_api_config_id, expensive_api_config_id, '
          'cheap_api_config_id, cleaner_api_config_id) VALUES (?, ?, ?, ?, ?)',
          ['legacy', 'fallback', 'explicit', '', ''],
        );
        await seeded.customStatement('PRAGMA user_version = 97');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        final row = await upgraded
            .customSelect(
              'SELECT expensive_api_config_id, cheap_api_config_id, '
              "cleaner_api_config_id FROM studio_preset_rows WHERE preset_id = 'default'",
            )
            .getSingle();
        final columns = await upgraded
            .customSelect("PRAGMA table_info('studio_config_rows')")
            .get();
        final names = columns
            .map((column) => column.read<String>('name'))
            .toSet();

        expect(row.read<String>('expensive_api_config_id'), 'explicit');
        expect(row.read<String>('cheap_api_config_id'), 'fallback');
        expect(row.read<String>('cleaner_api_config_id'), 'fallback');
        expect(names, isNot(contains('final_preset_id')));
        expect(names, isNot(contains('run_api_config_id')));
        expect(names, isNot(contains('run_model_override')));
        expect(names, isNot(contains('expensive_api_config_id')));
      },
    );

    test(
      'v99 preserves distinct profile payloads in default and variants',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_studio_presets_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        final defaultBefore = await seeded
            .customSelect(
              'SELECT blocks_json, agent_enabled_json, execution_mode '
              "FROM studio_preset_rows WHERE preset_id = 'default'",
            )
            .getSingle();
        final customBlocks = jsonEncode([
          {
            'id': 'custom',
            'type': 'instruction',
            'content': 'custom topology',
            'section': 'final',
          },
        ]);
        await seeded.customStatement(
          'INSERT INTO studio_preset_rows '
          '(preset_id, name, blocks_json, agent_enabled_json, execution_mode, '
          'updated_at) VALUES (?, ?, ?, ?, ?, ?)',
          ['custom', 'Custom', customBlocks, '{"final":true}', 'direct', 77],
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN profile_id '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN profile_name '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN broadcast_blocks_json '
          "TEXT NOT NULL DEFAULT '[]'",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN agents_json '
          "TEXT NOT NULL DEFAULT '[]'",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN expensive_api_config_id '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN cheap_api_config_id '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN cleaner_api_config_id '
          "TEXT NOT NULL DEFAULT ''",
        );
        await seeded.customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN max_final_history_messages '
          'INTEGER NOT NULL DEFAULT 30',
        );
        final olderAgents = jsonEncode([
          {'id': 'final', 'controllerId': 'final'},
        ]);
        final newerAgents = jsonEncode([
          {'id': 'continuity', 'controllerId': 'continuity'},
          {'id': 'final', 'controllerId': 'final'},
        ]);
        await seeded.customStatement(
          'INSERT INTO studio_config_rows '
          '(session_id, profile_id, profile_name, agents_json, '
          'expensive_api_config_id, max_final_history_messages, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            'binding-newer',
            'profile-new',
            'Newer Binding',
            olderAgents,
            'binding-api',
            99,
            999,
          ],
        );
        await seeded.customStatement(
          'INSERT INTO studio_config_rows '
          '(session_id, profile_id, profile_name, enabled, agents_json, '
          'expensive_api_config_id, max_final_history_messages, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?)',
          [
            'profile-old',
            'profile-old',
            'Old Profile',
            1,
            olderAgents,
            'old-api',
            12,
            10,
            'profile-new',
            'profile-new',
            'New Profile',
            1,
            newerAgents,
            'new-api',
            24,
            20,
          ],
        );
        await seeded.customStatement('PRAGMA user_version = 98');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(upgraded.close);
        final presets = await upgraded
            .customSelect(
              'SELECT preset_id, name, blocks_json, agents_json, '
              'expensive_api_config_id, max_final_history_messages, '
              'agent_enabled_json, execution_mode '
              'FROM studio_preset_rows ORDER BY preset_id',
            )
            .get();
        final migrated = presets.where(
          (row) => row.read<String>('preset_id').startsWith('migrated_'),
        );
        final defaultAfter = presets.singleWhere(
          (row) => row.read<String>('preset_id') == 'default',
        );
        final customAfter = presets.singleWhere(
          (row) => row.read<String>('preset_id') == 'custom',
        );
        final variant = migrated.single;
        final configColumns = await upgraded
            .customSelect("PRAGMA table_info('studio_config_rows')")
            .get();
        final configNames = configColumns
            .map((row) => row.read<String>('name'))
            .toSet();

        expect(defaultAfter.read<String>('expensive_api_config_id'), 'new-api');
        expect(defaultAfter.read<int>('max_final_history_messages'), 24);
        expect(
          jsonDecode(defaultAfter.read<String>('agents_json')),
          hasLength(2),
        );
        expect(customAfter.read<String>('execution_mode'), 'direct');
        expect(
          customAfter.read<String>('agent_enabled_json'),
          '{"final":true}',
        );
        // v106 migration repairs the custom block's routing (section →
        // injectionPoint), so the JSON no longer matches the seeded literal.
        final customBlocksAfter =
            jsonDecode(customAfter.read<String>('blocks_json')) as List;
        expect(customBlocksAfter, hasLength(1));
        expect(customBlocksAfter[0]['id'], 'custom');
        expect(customBlocksAfter[0]['injectionPoint'], 'final');
        expect(customBlocksAfter[0]['section'], '');
        expect(customAfter.read<String>('expensive_api_config_id'), 'new-api');
        expect(customAfter.read<int>('max_final_history_messages'), 24);
        expect(variant.read<String>('name'), contains('Old Profile'));
        expect(variant.read<String>('expensive_api_config_id'), 'old-api');
        expect(variant.read<int>('max_final_history_messages'), 12);
        // v106 migration canonicalizes and migrates the default preset's
        // blocks (section → injectionPoint, dead sections dropped), so the
        // raw JSON differs. Verify the default preset still has blocks.
        final defaultAfterBlocks =
            jsonDecode(defaultAfter.read<String>('blocks_json')) as List;
        expect(defaultAfterBlocks, isNotEmpty);
        expect(
          variant.read<String>('agent_enabled_json'),
          defaultBefore.read<String>('agent_enabled_json'),
        );
        expect(
          variant.read<String>('execution_mode'),
          defaultBefore.read<String>('execution_mode'),
        );
        expect(configNames, isNot(contains('agents_json')));
        expect(configNames, isNot(contains('expensive_api_config_id')));
        expect(configNames, isNot(contains('max_final_history_messages')));
      },
    );

    test('current schema includes atomic character fact tables', () async {
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 122);

      final factColumns = await db
          .customSelect("PRAGMA table_info('character_knowledge_fact_rows')")
          .get();
      final factNames = factColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(
        factNames,
        containsAll(<String>{
          'id',
          'chat_session_id',
          'knower_key',
          'subject_key',
          'fact_class',
          'scope_key',
          'predicate',
          'object',
          'epistemic_state',
          'source_message_id',
          'source_swipe_id',
          'source_agent_swipe_id',
          'supersedes_id',
          'lifecycle',
        }),
      );

      final baselineColumns = await db
          .customSelect("PRAGMA table_info('character_session_baseline_rows')")
          .get();
      final baselineNames = baselineColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(
        baselineNames,
        containsAll(<String>{
          'chat_session_id',
          'character_id',
          'baseline_card_json',
          'baseline_hash',
          'source_hash_last_seen',
          'card_update_policy',
        }),
      );
    });

    test(
      'current API config schema includes extra request parameters',
      () async {
        final columns = await db
            .customSelect("PRAGMA table_info('api_configs')")
            .get();
        final names = columns.map((row) => row.read<String>('name')).toSet();

        expect(
          names,
          containsAll([
            'extra_request_parameters_json',
            'include_last_reasoning',
            'show_native_reasoning',
            'omit_top_k',
            'omit_frequency_penalty',
            'omit_presence_penalty',
            'use_responses_api',
          ]),
        );
      },
    );

    test('v77 adds reversible reconciliation cleanup journal', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_reconcile_journal_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'DROP TABLE ledger_reconciliation_cleanup_journals',
      );
      await seeded.customStatement('PRAGMA user_version = 76');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final columns = await upgraded
          .customSelect(
            "PRAGMA table_info('ledger_reconciliation_cleanup_journals')",
          )
          .get();

      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll([
          'id',
          'session_id',
          'endpoint_message_id',
          'message_ids_json',
          'before_images_json',
          'created_at',
        ]),
      );
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test(
      'v76 preserves native reasoning visibility from omit_reasoning',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_reasoning_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          "INSERT INTO api_configs (config_id, name, omit_reasoning) "
          "VALUES ('shown', 'Shown', 0)",
        );
        await seeded.customStatement(
          "INSERT INTO api_configs (config_id, name, omit_reasoning) "
          "VALUES ('hidden', 'Hidden', 1)",
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN show_native_reasoning',
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN omit_top_k',
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN omit_frequency_penalty',
        );
        await seeded.customStatement(
          'ALTER TABLE api_configs DROP COLUMN omit_presence_penalty',
        );
        await seeded.customStatement('PRAGMA user_version = 75');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        final rows = await upgraded
            .customSelect(
              'SELECT config_id, show_native_reasoning, omit_top_k, '
              'omit_frequency_penalty, omit_presence_penalty '
              'FROM api_configs ORDER BY config_id',
            )
            .get();

        expect(rows[0].read<String>('config_id'), 'hidden');
        expect(rows[0].read<bool>('show_native_reasoning'), isFalse);
        expect(rows[1].read<String>('config_id'), 'shown');
        expect(rows[1].read<bool>('show_native_reasoning'), isTrue);
        for (final row in rows) {
          expect(row.read<bool>('omit_top_k'), isFalse);
          expect(row.read<bool>('omit_frequency_penalty'), isFalse);
          expect(row.read<bool>('omit_presence_penalty'), isFalse);
        }
      },
    );

    test('v79 migrates the reasoning history toggle to a count', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_reasoning_count_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'INSERT INTO api_configs '
        '(config_id, name, include_last_reasoning) VALUES (?, ?, ?)',
        ['disabled', 'Disabled', 0],
      );
      await seeded.customStatement(
        'INSERT INTO api_configs '
        '(config_id, name, include_last_reasoning) VALUES (?, ?, ?)',
        ['enabled', 'Enabled', 1],
      );
      await seeded.customStatement(
        'ALTER TABLE api_configs DROP COLUMN reasoning_history_count',
      );
      await seeded.customStatement('PRAGMA user_version = 77');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final rows = await upgraded
          .customSelect(
            'SELECT config_id, reasoning_history_count '
            'FROM api_configs ORDER BY config_id',
          )
          .get();

      expect(rows[0].read<String>('config_id'), 'disabled');
      expect(rows[0].read<int>('reasoning_history_count'), 0);
      expect(rows[1].read<String>('config_id'), 'enabled');
      expect(rows[1].read<int>('reasoning_history_count'), 1);
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v80 adds Responses API toggle defaulting to off', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_responses_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'INSERT INTO api_configs (config_id, name) VALUES (?, ?)',
        ['existing', 'Existing'],
      );
      await seeded.customStatement(
        'ALTER TABLE api_configs DROP COLUMN use_responses_api',
      );
      await seeded.customStatement('PRAGMA user_version = 79');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final row = await upgraded
          .customSelect(
            'SELECT use_responses_api FROM api_configs WHERE config_id = ?',
            variables: [Variable.withString('existing')],
          )
          .getSingle();

      expect(row.read<bool>('use_responses_api'), isFalse);
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v81 adds composite embedding source index', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_embedding_index_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('DROP INDEX idx_embeddings_source_type_id');
      await seeded.customStatement('PRAGMA user_version = 80');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final indexes = await upgraded
          .customSelect("PRAGMA index_list('embeddings')")
          .get();

      expect(
        indexes.map((row) => row.read<String>('name')),
        contains('idx_embeddings_source_type_id'),
      );
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v82 creates rewrite persistence schema and provenance columns', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_rewrite_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      for (final table in [
        'character_revision_rows',
        'applied_canon_transition_rows',
        'rewrite_jobs',
        'rewrite_operations',
        'rewrite_operation_revisions',
        'rewrite_evidence_rows',
        'canon_transition_fact_refs',
      ]) {
        await seeded.customStatement('DROP TABLE $table');
      }
      await seeded.customStatement(
        'ALTER TABLE character_knowledge_fact_rows DROP COLUMN basis_revision',
      );
      await seeded.customStatement(
        'ALTER TABLE character_knowledge_fact_rows DROP COLUMN basis_revision_hash',
      );
      await seeded.customStatement(
        'ALTER TABLE tracker_rows DROP COLUMN basis_revision',
      );
      await seeded.customStatement(
        'ALTER TABLE tracker_rows DROP COLUMN basis_revision_hash',
      );
      await seeded.customStatement('PRAGMA user_version = 81');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      for (final table in [
        'character_revision_rows',
        'applied_canon_transition_rows',
        'rewrite_jobs',
        'rewrite_operations',
        'rewrite_operation_revisions',
        'rewrite_evidence_rows',
        'canon_transition_fact_refs',
      ]) {
        final columns = await upgraded
            .customSelect("PRAGMA table_info('$table')")
            .get();
        expect(columns, isNotEmpty, reason: table);
      }
      for (final table in ['character_knowledge_fact_rows', 'tracker_rows']) {
        final columns = await upgraded
            .customSelect("PRAGMA table_info('$table')")
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          containsAll(['basis_revision', 'basis_revision_hash']),
          reason: table,
        );
      }
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v83 rebuilds interim text revision columns without losing rows', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_revision_types_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      const tables = [
        'tracker_rows',
        'character_knowledge_fact_rows',
        'character_revision_rows',
        'applied_canon_transition_rows',
        'rewrite_jobs',
        'rewrite_operation_revisions',
      ];
      final schemas = <String, String>{};
      for (final table in tables) {
        final row = await seeded
            .customSelect(
              "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
              variables: [Variable.withString(table)],
            )
            .getSingle();
        schemas[table] = row.read<String>('sql');
        await seeded.customStatement('DROP TABLE $table');
      }
      for (final schema in schemas.values) {
        await seeded.customStatement(
          schema
              .replaceAll('basis_revision INTEGER', 'basis_revision TEXT')
              .replaceAll('revision INTEGER', 'revision TEXT'),
        );
      }
      await seeded.customStatement(
        "INSERT INTO tracker_rows (session_id, name, basis_revision) VALUES ('s', 't', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO character_knowledge_fact_rows (id, chat_session_id, knower_key, subject_key, fact_class, predicate, object, epistemic_state, basis_revision) VALUES ('f', 's', 'k', 'subject', 'fact', 'p', 'o', 'known', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO character_revision_rows (character_id, revision, revision_hash, snapshot_json) VALUES ('c', '7', 'hash', '{}')",
      );
      await seeded.customStatement(
        "INSERT INTO applied_canon_transition_rows (id, chat_session_id, character_id, transition_json, basis_revision) VALUES ('t', 's', 'c', '{}', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, basis_revision) VALUES ('j', 's', 'c', '7')",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_operation_revisions (rewrite_operation_id, revision, snapshot_json) VALUES ('o', '7', '{}')",
      );
      await seeded.customStatement('PRAGMA user_version = 82');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();
      for (final (table, column) in const [
        ('tracker_rows', 'basis_revision'),
        ('character_knowledge_fact_rows', 'basis_revision'),
        ('character_revision_rows', 'revision'),
        ('applied_canon_transition_rows', 'basis_revision'),
        ('rewrite_jobs', 'basis_revision'),
        ('rewrite_operation_revisions', 'revision'),
      ]) {
        final info = await upgraded
            .customSelect("PRAGMA table_info('$table')")
            .get();
        final type = info
            .singleWhere((row) => row.read<String>('name') == column)
            .read<String>('type');
        expect(type.toUpperCase(), 'INTEGER', reason: '$table.$column');
      }
      expect(
        await upgraded
            .customSelect('SELECT basis_revision FROM tracker_rows')
            .getSingle(),
        isNotNull,
      );
      final values = await upgraded.customSelect('''
        SELECT (SELECT basis_revision FROM tracker_rows) AS tracker,
               (SELECT basis_revision FROM character_knowledge_fact_rows) AS fact,
               (SELECT revision FROM character_revision_rows) AS character_revision,
               (SELECT basis_revision FROM applied_canon_transition_rows) AS transition,
               (SELECT basis_revision FROM rewrite_jobs) AS job,
               (SELECT revision FROM rewrite_operation_revisions) AS operation_revision
      ''').getSingle();
      for (final name in [
        'tracker',
        'fact',
        'character_revision',
        'transition',
        'job',
        'operation_revision',
      ]) {
        expect(values.read<int>(name), 7, reason: name);
      }
    });

    test(
      'v84 transition schema has queryable columns and lineage constraints',
      () async {
        final transitionColumns = await db
            .customSelect("PRAGMA table_info('applied_canon_transition_rows')")
            .get();
        final byName = {
          for (final row in transitionColumns) row.read<String>('name'): row,
        };
        expect(
          byName.keys,
          containsAll([
            'character_id',
            'chat_session_id',
            'rewrite_operation_id',
            'revision',
            'revision_hash',
            'semantic_scope_key',
            'canonical_claim',
            'promotion_destination',
            'affected_tracker_keys_json',
          ]),
        );
        expect(byName['chat_session_id']!.read<int>('notnull'), 0);
        expect(
          byName['revision']!.read<String>('type').toUpperCase(),
          'INTEGER',
        );
        final indexes = await db
            .customSelect("PRAGMA index_list('applied_canon_transition_rows')")
            .get();
        expect(
          indexes.map((row) => row.read<String>('name')),
          containsAll([
            'idx_applied_canon_transition_session',
            'idx_applied_canon_transition_character',
            'idx_applied_canon_transition_operation',
          ]),
        );

        final revisions = await db
            .customSelect("PRAGMA table_info('character_revision_rows')")
            .get();
        expect(
          revisions.map((row) => row.read<String>('name')),
          contains('parent_revision_hash'),
        );
        final revisionIndexes = await db
            .customSelect("PRAGMA index_list('character_revision_rows')")
            .get();
        final hashIndex = revisionIndexes.singleWhere(
          (row) => row.read<String>('name') == 'idx_character_revision_hash',
        );
        expect(hashIndex.read<int>('unique'), 0);

        await db.customStatement(
          'INSERT INTO character_revision_rows '
          '(character_id, revision, revision_hash, snapshot_json) '
          "VALUES ('repeatable', 1, 'same-hash', '{}'), "
          "('repeatable', 2, 'same-hash', '{}')",
        );
        await expectLater(
          db.customStatement(
            'INSERT INTO character_revision_rows '
            '(character_id, revision, revision_hash, snapshot_json) '
            "VALUES ('repeatable', 2, 'another-hash', '{}')",
          ),
          throwsA(anything),
        );
      },
    );

    test('v85 exposes durable rewrite CAS and apply columns', () async {
      final jobs = await db
          .customSelect("PRAGMA table_info('rewrite_jobs')")
          .get();
      final operations = await db
          .customSelect("PRAGMA table_info('rewrite_operations')")
          .get();
      expect(
        jobs.map((row) => row.read<String>('name')),
        containsAll([
          'version',
          'applied_character_revision',
          'applied_character_revision_hash',
        ]),
      );
      expect(
        operations.map((row) => row.read<String>('name')),
        containsAll([
          'current_revision',
          'decision',
          'validation_status',
          'decision_revision',
          'applied_character_revision',
          'applied_character_revision_hash',
        ]),
      );
      final indexes = await db
          .customSelect("PRAGMA index_list('rewrite_operations')")
          .get();
      expect(
        indexes.map((row) => row.read<String>('name')),
        contains('idx_rewrite_operation_apply_cas'),
      );

      for (final statement in [
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, decision) "
            "VALUES ('invalid-decision', 'j', 's', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, validation_status) "
            "VALUES ('invalid-validation', 'j', 's', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, current_revision) "
            "VALUES ('invalid-current-revision', 'j', 's', 0)",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, decision_revision) "
            "VALUES ('invalid-decision-revision', 'j', 's', -1)",
      ]) {
        await expectLater(db.customStatement(statement), throwsA(anything));
      }
    });

    test(
      'v85 rebuilds v84 rewrite operations with constraints and CAS index',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_rewrite_cas_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'DROP INDEX idx_rewrite_operation_apply_cas',
        );
        await seeded.customStatement('DROP TABLE rewrite_operations');
        await seeded.customStatement('DROP TABLE rewrite_jobs');
        await seeded.customStatement('''
        CREATE TABLE rewrite_jobs (
          id TEXT NOT NULL PRIMARY KEY, chat_session_id TEXT NOT NULL,
          character_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
          request_json TEXT NOT NULL DEFAULT '{}', basis_revision INTEGER NOT NULL DEFAULT 0,
          basis_revision_hash TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0)
      ''');
        await seeded.customStatement('''
        CREATE TABLE rewrite_operations (
          id TEXT NOT NULL PRIMARY KEY, rewrite_job_id TEXT NOT NULL,
          chat_session_id TEXT NOT NULL, operation_json TEXT NOT NULL DEFAULT '{}',
          status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0)
      ''');
        await seeded.customStatement(
          "INSERT INTO rewrite_jobs (id, chat_session_id, character_id) VALUES ('j', 's', 'c')",
        );
        await seeded.customStatement(
          "INSERT INTO rewrite_operations "
          "(id, rewrite_job_id, chat_session_id, operation_json, status, created_at, updated_at) "
          "VALUES ('o', 'j', 's', '{\"preserved\":true}', 'complete', 12, 34)",
        );
        await seeded.customStatement('PRAGMA user_version = 84');
        await seeded.close();
        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() => upgraded.close());
        final row = await upgraded.customSelect('''
        SELECT (SELECT version FROM rewrite_jobs WHERE id = 'j') AS job_version,
          (SELECT operation_json FROM rewrite_operations WHERE id = 'o') AS operation_json,
          (SELECT status FROM rewrite_operations WHERE id = 'o') AS status,
          (SELECT created_at FROM rewrite_operations WHERE id = 'o') AS created_at,
          (SELECT updated_at FROM rewrite_operations WHERE id = 'o') AS updated_at,
          (SELECT decision FROM rewrite_operations WHERE id = 'o') AS decision,
          (SELECT validation_status FROM rewrite_operations WHERE id = 'o') AS validation_status,
          (SELECT current_revision FROM rewrite_operations WHERE id = 'o') AS current_revision
      ''').getSingle();
        expect(row.read<int>('job_version'), 1);
        expect(row.read<String>('operation_json'), '{"preserved":true}');
        // v86 installs the operation status CHECK and normalizes the
        // out-of-domain legacy 'complete' status to the neutral 'pending'.
        expect(row.read<String>('status'), 'pending');
        expect(row.read<int>('created_at'), 12);
        expect(row.read<int>('updated_at'), 34);
        expect(row.read<String>('decision'), 'pending');
        expect(row.read<String>('validation_status'), 'pending');
        expect(row.read<int>('current_revision'), 1);
        final indexes = await upgraded
            .customSelect("PRAGMA index_list('rewrite_operations')")
            .get();
        expect(
          indexes.map((index) => index.read<String>('name')),
          contains('idx_rewrite_operation_apply_cas'),
        );
        for (final statement in [
          "UPDATE rewrite_operations SET decision = 'unknown' WHERE id = 'o'",
          "UPDATE rewrite_operations SET validation_status = 'unknown' WHERE id = 'o'",
          "UPDATE rewrite_operations SET current_revision = 0 WHERE id = 'o'",
          "UPDATE rewrite_operations SET decision_revision = -1 WHERE id = 'o'",
        ]) {
          await expectLater(
            upgraded.customStatement(statement),
            throwsA(anything),
          );
        }
      },
    );

    test('v86 adds lifecycle columns, unique request key, and status CHECKs', () async {
      final jobs = await db
          .customSelect("PRAGMA table_info('rewrite_jobs')")
          .get();
      final byJobColumn = {
        for (final row in jobs) row.read<String>('name'): row,
      };
      expect(
        byJobColumn.keys,
        containsAll(['status_reason', 'canon_stamp', 'request_key']),
      );
      expect(byJobColumn['status_reason']!.read<int>('notnull'), 0);
      expect(byJobColumn['request_key']!.read<int>('notnull'), 0);
      expect(byJobColumn['canon_stamp']!.read<int>('notnull'), 1);

      final jobIndexes = await db
          .customSelect("PRAGMA index_list('rewrite_jobs')")
          .get();
      final requestKeyIndex = jobIndexes.singleWhere(
        (row) => row.read<String>('name') == 'idx_rewrite_job_request_key',
      );
      expect(requestKeyIndex.read<int>('unique'), 1);

      // NULL request keys remain distinct; duplicate non-null keys conflict.
      for (final id in ['null-a', 'null-b']) {
        await db.customStatement(
          "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status) "
          "VALUES (?, 's', 'c', 'pending')",
          [id],
        );
      }
      await db.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, request_key) "
        "VALUES ('keyed-a', 's', 'c', 'rk')",
      );
      await expectLater(
        db.customStatement(
          "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, request_key) "
          "VALUES ('keyed-b', 's', 'c', 'rk')",
        ),
        throwsA(anything),
      );

      // Fresh-schema status CHECKs reject out-of-domain values under direct SQL.
      for (final statement in [
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status) "
            "VALUES ('bad-job-status', 's', 'c', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, status) "
            "VALUES ('bad-op-status', 'null-a', 's', 'unknown')",
      ]) {
        await expectLater(db.customStatement(statement), throwsA(anything));
      }
      // Elegant statuses pass on both tables.
      await db.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status) "
        "VALUES ('generating-job', 's', 'c', 'generating')",
      );
      await db.customStatement(
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, status) "
        "VALUES ('reviewable-op', 'null-a', 's', 'reviewable')",
      );
    });

    test('v86 rebuilds v85 rewrite tables with lifecycle columns and CHECKs', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_rewrite_v86_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('DROP INDEX idx_rewrite_job_request_key');
      await seeded.customStatement('DROP TABLE rewrite_operations');
      await seeded.customStatement('DROP TABLE rewrite_jobs');
      // v85-shaped tables: CAS columns present, no lifecycle columns, and
      // (worst case) no CHECK constraints.
      await seeded.customStatement('''
        CREATE TABLE rewrite_jobs (
          id TEXT NOT NULL PRIMARY KEY, chat_session_id TEXT NOT NULL,
          character_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
          request_json TEXT NOT NULL DEFAULT '{}', basis_revision INTEGER NOT NULL DEFAULT 0,
          basis_revision_hash TEXT NOT NULL DEFAULT '',
          version INTEGER NOT NULL DEFAULT 1,
          applied_character_revision INTEGER NOT NULL DEFAULT 0,
          applied_character_revision_hash TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0)
      ''');
      await seeded.customStatement('''
        CREATE TABLE rewrite_operations (
          id TEXT NOT NULL PRIMARY KEY, rewrite_job_id TEXT NOT NULL,
          chat_session_id TEXT NOT NULL, operation_json TEXT NOT NULL DEFAULT '{}',
          status TEXT NOT NULL DEFAULT 'pending',
          current_revision INTEGER NOT NULL DEFAULT 1,
          decision TEXT NOT NULL DEFAULT 'pending',
          validation_status TEXT NOT NULL DEFAULT 'pending',
          decision_revision INTEGER NOT NULL DEFAULT 0,
          applied_character_revision INTEGER NOT NULL DEFAULT 0,
          applied_character_revision_hash TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0)
      ''');
      await seeded.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status, "
        "request_json, created_at) VALUES ('legacy-pending', 's', 'c', 'pending', "
        "'{\"kept\":true}', 7)",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status) "
        "VALUES ('legacy-applied', 's', 'c', 'applied')",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status) "
        "VALUES ('legacy-weird', 's', 'c', 'reviewing')",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, status) "
        "VALUES ('op-pending', 'legacy-pending', 's', 'pending')",
      );
      await seeded.customStatement(
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, status) "
        "VALUES ('op-reviewable', 'legacy-pending', 's', 'reviewable')",
      );
      await seeded.customStatement('PRAGMA user_version = 85');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);

      // Rows and payloads survive; legacy statuses pass through or are
      // normalized fail-closed, and new columns carry neutral defaults.
      final rows = await upgraded.customSelect('''
        SELECT id, status, status_reason, canon_stamp, request_key, request_json,
               created_at FROM rewrite_jobs ORDER BY id
      ''').get();
      expect(rows.map((row) => row.read<String>('id')), [
        'legacy-applied',
        'legacy-pending',
        'legacy-weird',
      ]);
      final byId = {for (final row in rows) row.read<String>('id'): row};
      expect(byId['legacy-pending']!.read<String>('status'), 'pending');
      expect(
        byId['legacy-pending']!.read<String>('request_json'),
        '{"kept":true}',
      );
      expect(byId['legacy-pending']!.read<int>('created_at'), 7);
      expect(byId['legacy-applied']!.read<String>('status'), 'applied');
      expect(byId['legacy-weird']!.read<String>('status'), 'cancelled');
      for (final row in rows) {
        expect(row.read<String?>('status_reason'), isNull);
        expect(row.read<String>('canon_stamp'), '');
        // Multiple upgraded NULL request keys stay distinct.
        expect(row.read<String?>('request_key'), isNull);
      }
      final operations = await upgraded
          .customSelect('SELECT id, status FROM rewrite_operations ORDER BY id')
          .get();
      expect(
        operations.map(
          (row) => '${row.read<String>('id')}:${row.read<String>('status')}',
        ),
        ['op-pending:pending', 'op-reviewable:reviewable'],
      );

      final jobIndexes = await upgraded
          .customSelect("PRAGMA index_list('rewrite_jobs')")
          .get();
      final requestKeyIndex = jobIndexes.singleWhere(
        (row) => row.read<String>('name') == 'idx_rewrite_job_request_key',
      );
      expect(requestKeyIndex.read<int>('unique'), 1);
      final operationIndexes = await upgraded
          .customSelect("PRAGMA index_list('rewrite_operations')")
          .get();
      expect(
        operationIndexes.map((row) => row.read<String>('name')),
        contains('idx_rewrite_operation_apply_cas'),
      );

      // Upgraded databases enforce all new and retained CHECK constraints.
      for (final statement in [
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status) "
            "VALUES ('bad-job', 's', 'c', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, status) "
            "VALUES ('bad-op', 'legacy-pending', 's', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, decision) "
            "VALUES ('bad-decision', 'legacy-pending', 's', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, validation_status) "
            "VALUES ('bad-validation', 'legacy-pending', 's', 'unknown')",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, current_revision) "
            "VALUES ('bad-revision', 'legacy-pending', 's', 0)",
        "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id, decision_revision) "
            "VALUES ('bad-decision-revision', 'legacy-pending', 's', -1)",
      ]) {
        await expectLater(
          upgraded.customStatement(statement),
          throwsA(anything),
        );
      }
      // Duplicate non-null request keys conflict; NULL keys stay distinct.
      await upgraded.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, request_key) "
        "VALUES ('keyed-a', 's', 'c', 'dup')",
      );
      await expectLater(
        upgraded.customStatement(
          "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, request_key) "
          "VALUES ('keyed-b', 's', 'c', 'dup')",
        ),
        throwsA(anything),
      );
      await upgraded.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id, status) "
        "VALUES ('another-null-key', 's', 'c', 'pending')",
      );
    });

    test(
      'v84 upgrades a v83 transition row with defaults and preserved payload',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_transition_v84_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });
        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'DROP TABLE applied_canon_transition_rows',
        );
        await seeded.customStatement('''
        CREATE TABLE applied_canon_transition_rows (
          id TEXT NOT NULL PRIMARY KEY,
          chat_session_id TEXT NOT NULL,
          character_id TEXT NOT NULL,
          transition_json TEXT NOT NULL,
          basis_revision INTEGER NOT NULL DEFAULT 0,
          basis_revision_hash TEXT NOT NULL DEFAULT '',
          applied_at INTEGER NOT NULL DEFAULT 0
        )
      ''');
        await seeded.customStatement('''
        INSERT INTO applied_canon_transition_rows
        (id, chat_session_id, character_id, transition_json, basis_revision,
         basis_revision_hash, applied_at)
        VALUES ('legacy-transition', 'legacy-session', 'legacy-character',
                '{"legacy":true}', 4, 'basis-hash', 5)
      ''');
        await seeded.customStatement('PRAGMA user_version = 83');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        final row = await upgraded.customSelect('''
        SELECT chat_session_id, character_id, transition_json, basis_revision,
               basis_revision_hash, rewrite_operation_id, revision,
               revision_hash, semantic_scope_key, canonical_claim,
               promotion_destination, affected_tracker_keys_json
        FROM applied_canon_transition_rows WHERE id = 'legacy-transition'
      ''').getSingle();
        expect(row.read<String>('chat_session_id'), 'legacy-session');
        expect(row.read<String>('character_id'), 'legacy-character');
        expect(row.read<String>('transition_json'), '{"legacy":true}');
        expect(row.read<int>('basis_revision'), 4);
        expect(row.read<String>('basis_revision_hash'), 'basis-hash');
        expect(row.read<String>('rewrite_operation_id'), '');
        expect(row.read<int>('revision'), 0);
        expect(row.read<String>('revision_hash'), '');
        expect(row.read<String>('semantic_scope_key'), '');
        expect(row.read<String>('canonical_claim'), '');
        expect(row.read<String>('promotion_destination'), '');
        expect(row.read<String>('affected_tracker_keys_json'), '[]');
      },
    );

    test('v70 refreshes only the default Ledger prompt block', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_ledger_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      final staleBlocks = [
        {
          'id': 'ledger_system',
          'name': 'Ledger system prompt',
          'kind': 'instruction',
          'role': 'system',
          'content': 'Promote facts into durableFacts.',
          'enabled': true,
          'order': 0,
          'section': 'ledger',
        },
        {
          'id': 'custom_block',
          'name': 'Custom block',
          'kind': 'instruction',
          'role': 'system',
          'content': 'keep this customization',
          'enabled': true,
          'order': 1,
          'section': 'ledger',
        },
      ];
      await seeded.customStatement(
        'UPDATE studio_preset_rows SET name = ?, blocks_json = ?, '
        'updated_at = ? WHERE preset_id = ?',
        ['Default Studio Preset', jsonEncode(staleBlocks), 1, 'default'],
      );
      await seeded.customStatement('PRAGMA user_version = 70');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
      final row = await upgraded
          .customSelect(
            'SELECT blocks_json FROM studio_preset_rows WHERE preset_id = ?',
            variables: [Variable.withString('default')],
          )
          .getSingle();
      final blocks = (jsonDecode(row.read<String>('blocks_json')) as List)
          .cast<Map<String, dynamic>>();
      final ledger = blocks.singleWhere(
        (block) => block['id'] == 'ledger_system',
      );
      final custom = blocks.singleWhere(
        (block) => block['id'] == 'custom_block',
      );
      expect(ledger['content'], isNot(contains('durableFacts')));
      expect(ledger['enabled'], isTrue);
      expect(custom['content'], 'keep this customization');
      expect(
        blocks.any((block) => block['id'] == 'ledger_reconciliation_prompt'),
        isTrue,
      );
    });

    test('v73 enables Ledger prompt without replacing its text', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_ledger_prompts_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      final blocks = [
        {
          'id': 'ledger_system',
          'name': 'Ledger system prompt',
          'kind': 'instruction',
          'role': 'system',
          'content': 'custom Ledger prompt',
          'enabled': false,
          'order': 0,
          'section': 'ledger',
        },
        {
          'id': 'ledger_reconciliation_prompt',
          'name': 'Ledger reconciliation prompt',
          'kind': 'instruction',
          'role': 'system',
          'content': 'custom reconciliation prompt',
          'enabled': true,
          'order': 1,
          'section': 'ledger',
        },
      ];
      await seeded.customStatement(
        'INSERT INTO studio_preset_rows '
        '(preset_id, name, blocks_json, updated_at) VALUES (?, ?, ?, ?)',
        ['separate_prompts', 'Separate prompts', jsonEncode(blocks), 1],
      );
      await seeded.customStatement('PRAGMA user_version = 73');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final row = await upgraded
          .customSelect(
            'SELECT blocks_json FROM studio_preset_rows WHERE preset_id = ?',
            variables: [Variable.withString('separate_prompts')],
          )
          .getSingle();
      final upgradedBlocks =
          (jsonDecode(row.read<String>('blocks_json')) as List)
              .cast<Map<String, dynamic>>();
      final ledger = upgradedBlocks.singleWhere(
        (block) => block['id'] == 'ledger_system',
      );
      final reconciliation = upgradedBlocks.singleWhere(
        (block) => block['id'] == 'ledger_reconciliation_prompt',
      );

      expect(ledger['enabled'], isTrue);
      expect(ledger['content'], 'custom Ledger prompt');
      expect(reconciliation['enabled'], isTrue);
      expect(reconciliation['content'], 'custom reconciliation prompt');
    });

    test('v67 upgrades to atomic character fact schema', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_atomic_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('PRAGMA user_version = 67');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
      final check = await upgraded.customSelect('PRAGMA integrity_check').get();
      expect(check.single.read<String>('integrity_check'), 'ok');
    });

    test(
      'v88 generation acceptances are fail-closed on upgrade to v89',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_lorebook_acceptance_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          'DROP TRIGGER IF EXISTS lorebook_use_acceptance_records_no_update',
        );
        await seeded.customStatement(
          'DROP TABLE lorebook_use_acceptance_records',
        );
        await seeded.customStatement('''
        CREATE TABLE lorebook_use_acceptance_records (
          acceptance_id TEXT NOT NULL PRIMARY KEY,
          session_id TEXT NOT NULL,
          message_id TEXT NOT NULL,
          swipe_id INTEGER NOT NULL,
          agent_swipe_id INTEGER NOT NULL,
          acceptance_kind TEXT NOT NULL,
          selected_lorebook_id TEXT,
          selected_entry_id TEXT,
          selected_entry_order INTEGER,
          evidence_json TEXT NOT NULL DEFAULT '{}',
          accepted_at INTEGER NOT NULL
        )
      ''');
        await seeded.customStatement('''
        INSERT INTO lorebook_use_acceptance_records
        (acceptance_id, session_id, message_id, swipe_id, agent_swipe_id,
         acceptance_kind, accepted_at)
        VALUES ('provisional', 'session', 'assistant', 0, 0, 'generation', 1)
      ''');
        await seeded.customStatement('PRAGMA user_version = 88');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        expect(
          await upgraded
              .customSelect('SELECT * FROM lorebook_use_acceptance_records')
              .get(),
          isEmpty,
        );
        final columns = await upgraded
            .customSelect(
              "PRAGMA table_info('lorebook_use_acceptance_records')",
            )
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          contains('accepted_by_user_message_id'),
        );
        await upgraded.customStatement('''
        INSERT INTO lorebook_use_manifests
        (session_id, message_id, swipe_id, agent_swipe_id, created_at)
        VALUES ('session', 'assistant', 0, 0, 1)
      ''');
        await upgraded.customStatement('''
        INSERT INTO lorebook_use_acceptance_records
        (acceptance_id, session_id, message_id, swipe_id, agent_swipe_id,
         acceptance_kind, accepted_by_user_message_id, accepted_at)
        VALUES ('variation', 'session', 'assistant', 0, 0, 'variation', 'user', 2)
      ''');
        await expectLater(
          upgraded.customStatement(
            "UPDATE lorebook_use_acceptance_records "
            "SET evidence_json = '{\"tampered\":true}' "
            "WHERE acceptance_id = 'variation'",
          ),
          throwsA(anything),
        );
      },
    );

    test('memory catalog table exists in current schema', () async {
      final rows = await db
          .customSelect("PRAGMA table_info('memory_catalog_rows')")
          .get();
      final names = rows.map((c) => c.read<String>('name')).toSet();

      expect(names, contains('chat_session_id'));
      expect(names, contains('memory_entry_id'));
      expect(names, contains('entry_revision'));
      expect(names, contains('source_hash'));
      expect(names, contains('entities_json'));
      expect(names, contains('locations_json'));
      expect(names, contains('topics_json'));
      expect(names, contains('message_range_start'));
      expect(names, contains('message_range_end'));
      expect(names, contains('token_count'));
      expect(names, contains('abstract_text'));
      expect(names, contains('stale'));
    });

    test(
      'v66 removes agentic micro-memory; v105 retires stored write-loop blocks',
      () async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_agentic_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        await seeded.customStatement(
          '''INSERT INTO memory_book_rows
           (session_id, entries_json, pending_drafts_json, settings_json,
            last_processed_message_count, updated_at)
           VALUES (?, ?, ?, '{}', 0, 0)''',
          [
            'session-1',
            '[{"id":"agent-entry","source":"agentic"},'
                '{"id":"range-entry","source":"scan"},'
                '{"id":"ledger-entry","source":"studio_ledger"}]',
            '[{"id":"agent-draft","source":"agentic"},'
                '{"id":"scan-draft","source":"scan"}]',
          ],
        );
        await seeded.customStatement(
          '''INSERT INTO embeddings (entry_id, source_type, source_id)
           VALUES ('agent-entry', 'memory_entry', 'memorybook_session-1'),
                  ('range-entry', 'memory_entry', 'memorybook_session-1')''',
        );
        await seeded.customStatement('''INSERT INTO memory_catalog_rows
           (id, chat_session_id, memory_entry_id)
           VALUES ('cat-agent', 'session-1', 'agent-entry'),
                  ('cat-range', 'session-1', 'range-entry')''');
        await seeded.customStatement('''INSERT INTO memory_entity_rows
           (id, chat_session_id, memory_entry_id, name)
           VALUES ('entity-agent', 'session-1', 'agent-entry', 'drop'),
                  ('entity-range', 'session-1', 'range-entry', 'keep')''');
        await seeded.customStatement('''INSERT INTO memory_salience_rows
           (id, chat_session_id, memory_entry_id)
           VALUES ('salience-agent', 'session-1', 'agent-entry'),
                  ('salience-range', 'session-1', 'range-entry')''');
        await seeded.customStatement(
          '''INSERT INTO studio_preset_rows
           (preset_id, name, blocks_json, updated_at)
           VALUES (?, ?, ?, 0), (?, ?, ?, 0)''',
          [
            'legacy-write-loop',
            'Legacy write-loop',
            '[{"id":"writeloop_system","name":"Legacy",'
                '"content":"Use writeMemory and {{existingBlock}}."}]',
            'custom-tracker-loop',
            'Custom tracker loop',
            '[{"id":"writeloop_system","name":"Custom",'
                '"content":"Track only weather changes."}]',
          ],
        );
        await seeded.customStatement('PRAGMA user_version = 65');
        await seeded.close();

        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        await upgraded.customSelect('SELECT 1').get();

        final row = await upgraded.customSelect(
          '''SELECT entries_json, pending_drafts_json
           FROM memory_book_rows WHERE session_id = 'session-1' ''',
        ).getSingle();
        expect(row.read<String>('entries_json'), contains('range-entry'));
        expect(row.read<String>('entries_json'), contains('ledger-entry'));
        expect(
          row.read<String>('entries_json'),
          isNot(contains('agent-entry')),
        );
        expect(row.read<String>('pending_drafts_json'), contains('scan-draft'));
        expect(
          row.read<String>('pending_drafts_json'),
          isNot(contains('agent-draft')),
        );

        for (final table in [
          'embeddings',
          'memory_catalog_rows',
          'memory_entity_rows',
          'memory_salience_rows',
        ]) {
          final rows = await upgraded
              .customSelect('SELECT * FROM $table')
              .get();
          expect(rows, hasLength(1), reason: table);
        }

        final presetRows = await upgraded.customSelect(
          '''SELECT preset_id, blocks_json FROM studio_preset_rows
           WHERE preset_id IN ('legacy-write-loop', 'custom-tracker-loop')''',
        ).get();
        final presets = {
          for (final preset in presetRows)
            preset.read<String>('preset_id'): preset.read<String>(
              'blocks_json',
            ),
        };
        expect(
          presets['legacy-write-loop'] ?? '[]',
          isNot(contains('writeloop_system')),
        );
        expect(
          presets['custom-tracker-loop'] ?? '[]',
          isNot(contains('writeloop_system')),
        );
      },
    );

    test('v106 repairs corrupted preset block injectionPoint routing', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_routing_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      // Seed a preset with canonical final/cleaner/ledger block IDs but
      // corrupted injectionPoint=pregen (the symptom of the old codec that
      // did not read injectionPoint from JSON).
      await seeded.customStatement(
        '''INSERT INTO studio_preset_rows
           (preset_id, name, blocks_json, updated_at)
           VALUES (?, ?, ?, 0)''',
        [
          'corrupted-routing',
          'Corrupted routing',
          jsonEncode([
            {
              'id': 'final_main_prompt',
              'name': 'Final Main Prompt',
              'type': 'instruction',
              'content': 'Write the reply.',
              'enabled': true,
              'order': 0,
              'section': '',
              'injectionPoint': 'pregen',
            },
            {
              'id': 'cleaner_system',
              'name': 'Cleaner System',
              'type': 'instruction',
              'content': 'Clean the reply.',
              'enabled': true,
              'order': 1,
              'section': '',
              'injectionPoint': 'pregen',
            },
            {
              'id': 'ledger_system',
              'name': 'Ledger System',
              'type': 'instruction',
              'content': 'Maintain the ledger.',
              'enabled': true,
              'order': 2,
              'section': '',
              'injectionPoint': 'pregen',
            },
          ]),
        ],
      );
      await seeded.customStatement('PRAGMA user_version = 105');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final row = await upgraded
          .customSelect(
            "SELECT blocks_json FROM studio_preset_rows WHERE preset_id = 'corrupted-routing'",
          )
          .getSingle();
      final blocks = (jsonDecode(row.read<String>('blocks_json')) as List)
          .cast<Map<String, dynamic>>();
      final injectionPoints = {
        for (final b in blocks) b['id']: b['injectionPoint'],
      };
      expect(injectionPoints['final_main_prompt'], 'final');
      expect(injectionPoints['cleaner_system'], 'cleaner');
      expect(injectionPoints['ledger_system'], 'ledger');
    });

    test(
      'post-restore purge removes reintroduced agentic micro-memory',
      () async {
        await db.customStatement(
          '''INSERT INTO memory_book_rows
           (session_id, entries_json, pending_drafts_json, settings_json,
            last_processed_message_count, updated_at)
           VALUES (?, ?, ?, '{}', 0, 0)''',
          [
            'restored-session',
            '[{"id":"restored-agent","source":"agentic"},'
                '{"id":"restored-range","source":"scan"}]',
            '[{"id":"restored-draft","source":"agentic"},'
                '{"id":"restored-scan-draft","source":"scan"}]',
          ],
        );
        await db.customStatement(
          '''INSERT INTO embeddings (entry_id, source_type, source_id)
           VALUES ('restored-agent', 'memory_entry',
                   'memorybook_restored-session'),
                  ('restored-range', 'memory_entry',
                   'memorybook_restored-session')''',
        );

        await db.purgeRetiredAgenticMicroMemory();

        final row = await db.customSelect(
          '''SELECT entries_json, pending_drafts_json
           FROM memory_book_rows WHERE session_id = 'restored-session' ''',
        ).getSingle();
        expect(
          row.read<String>('entries_json'),
          isNot(contains('restored-agent')),
        );
        expect(row.read<String>('entries_json'), contains('restored-range'));
        expect(
          row.read<String>('pending_drafts_json'),
          isNot(contains('restored-draft')),
        );
        expect(
          row.read<String>('pending_drafts_json'),
          contains('restored-scan-draft'),
        );
        final embeddings = await db
            .customSelect('SELECT entry_id FROM embeddings')
            .get();
        expect(embeddings.map((row) => row.read<String>('entry_id')), [
          'restored-range',
        ]);
      },
    );

    test('memory graph tables exist in current schema (v35)', () async {
      final entityCols = await db
          .customSelect("PRAGMA table_info('memory_entity_rows')")
          .get();
      final entityNames = entityCols.map((c) => c.read<String>('name')).toSet();
      expect(entityNames, contains('chat_session_id'));
      expect(entityNames, contains('memory_entry_id'));
      expect(entityNames, contains('name'));
      expect(entityNames, contains('entity_type'));
      expect(entityNames, contains('salience_avg'));
      expect(entityNames, contains('source_hash'));

      final salienceCols = await db
          .customSelect("PRAGMA table_info('memory_salience_rows')")
          .get();
      final salienceNames = salienceCols
          .map((c) => c.read<String>('name'))
          .toSet();
      expect(salienceNames, contains('chat_session_id'));
      expect(salienceNames, contains('memory_entry_id'));
      expect(salienceNames, contains('score'));
      expect(salienceNames, contains('emotional_tags_json'));
      expect(salienceNames, contains('narrative_flags_json'));

      final cadenceCols = await db
          .customSelect("PRAGMA table_info('memory_cadence_rows')")
          .get();
      final cadenceNames = cadenceCols
          .map((c) => c.read<String>('name'))
          .toSet();
      expect(cadenceNames, contains('chat_session_id'));
      expect(cadenceNames, contains('assistant_messages_since_last_run'));
      expect(cadenceNames, contains('last_run_kind'));

      final consolidationCols = await db
          .customSelect("PRAGMA table_info('memory_consolidation_rows')")
          .get();
      final consolidationNames = consolidationCols
          .map((c) => c.read<String>('name'))
          .toSet();
      expect(consolidationNames, contains('chat_session_id'));
      expect(consolidationNames, contains('tier'));
      expect(consolidationNames, contains('summary'));
      expect(consolidationNames, contains('status'));
      expect(consolidationNames, contains('error_message'));
    });

    test(
      'v90/v91 reconciliation journal schema is immutable and genesis-safe',
      () async {
        for (final table in [
          'reconciliation_successful_runs',
          'reconciliation_run_invalidations',
          'ledger_reconciliation_cursors',
        ]) {
          final columns = await db
              .customSelect("PRAGMA table_info('$table')")
              .get();
          expect(columns, isNotEmpty, reason: table);
          final trigger = await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = '${table}_no_update'",
              )
              .getSingleOrNull();
          expect(trigger, isNotNull, reason: '$table no-update trigger');
        }
        final runIndexes = await db
            .customSelect("PRAGMA index_list('reconciliation_successful_runs')")
            .get();
        expect(
          runIndexes.map((row) => row.read<String>('name')),
          containsAll([
            'idx_reconciliation_run_endpoint',
            'idx_reconciliation_run_content',
            'idx_reconciliation_run_chain',
          ]),
        );
        await expectLater(
          db.customStatement(
            "INSERT INTO ledger_reconciliation_cursors (session_id, sequence, predecessor_hash, through_run_id, through_run_ordinal, through_run_chain_hash, cursor_hash, created_at) VALUES ('s', 1, 'not-genesis', 'run', 1, 'chain', 'cursor', 1)",
          ),
          throwsA(anything),
        );
        await db.customStatement(
          "INSERT INTO ledger_reconciliation_cursors (session_id, sequence, predecessor_hash, through_run_id, through_run_ordinal, through_run_chain_hash, cursor_hash, created_at) VALUES ('s', 1, '', 'run', 1, 'chain', 'cursor', 1)",
        );
        await expectLater(
          db.customStatement(
            "UPDATE ledger_reconciliation_cursors SET cursor_hash = 'changed' WHERE session_id = 's'",
          ),
          throwsA(anything),
        );
      },
    );

    test(
      'v92 evolution schema has exclusive claims and immutable output',
      () async {
        for (final table in [
          'card_evolution_claims',
          'card_evolution_proposal_runs',
        ]) {
          expect(
            await db.customSelect("PRAGMA table_info('$table')").get(),
            isNotEmpty,
          );
        }
        final indexes = await db
            .customSelect("PRAGMA index_list('card_evolution_claims')")
            .get();
        expect(
          indexes.map((row) => row.read<String>('name')),
          containsAll([
            'idx_card_evolution_claim_input',
            'idx_card_evolution_active_claim',
          ]),
        );
        final trigger = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = 'card_evolution_proposal_runs_no_update'",
            )
            .getSingleOrNull();
        expect(trigger, isNotNull);
      },
    );

    test('v116 collector journal has durable cadence identities', () async {
      final columns = await db
          .customSelect("PRAGMA table_info('card_evolution_collector_runs')")
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll([
          'collector_ordinal',
          'reconciliation_run_id',
          'reconciliation_chain_hash',
          'range_hash',
          'input_hash',
          'status',
          'lease_expires_at',
          'completed_at',
        ]),
      );
      final indexes = await db
          .customSelect("PRAGMA index_list('card_evolution_collector_runs')")
          .get();
      expect(
        indexes.map((row) => row.read<String>('name')),
        containsAll([
          'idx_card_evolution_collector_session_ordinal',
          'idx_card_evolution_collector_reconciliation',
        ]),
      );
    });

    test('v117 observation retrieval metadata is durable', () async {
      final columns = await db
          .customSelect("PRAGMA table_info('card_evolution_observations')")
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll(['retrieval_keys_json', 'target_kind']),
      );
      final retrieval = columns.singleWhere(
        (row) => row.read<String>('name') == 'retrieval_keys_json',
      );
      expect(retrieval.read<String?>('dflt_value'), "'[]'");
    });

    test('v116 to v117 safely backfills only exact legacy targets', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_observation_v117_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        "INSERT INTO card_evolution_observations "
        "(id,session_id,character_id,run_ordinal,semantic_scope_key,observed_change,evidence_message_ids,confidence,status,first_seen_run,created_at,updated_at,lorebook_entry_id) "
        "VALUES ('lore','s','c',1,'npc:Люси','fact','[]',.8,'active',1,1,1,'book:entry'),"
        "('unknown','s','c',1,'relationship:Люси','fact','[]',.8,'active',1,1,1,NULL)",
      );
      await seeded.customStatement(
        'ALTER TABLE card_evolution_observations DROP COLUMN retrieval_keys_json',
      );
      await seeded.customStatement(
        'ALTER TABLE card_evolution_observations DROP COLUMN target_kind',
      );
      await seeded.customStatement('PRAGMA user_version = 116');
      await seeded.close();
      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() => upgraded.close());
      final rows = await upgraded
          .customSelect(
            'SELECT id,retrieval_keys_json,target_kind FROM card_evolution_observations ORDER BY id',
          )
          .get();
      expect(rows.first.read<String>('retrieval_keys_json'), '["book:entry"]');
      expect(rows.first.read<String>('target_kind'), 'injected_lorebook_entry');
      expect(rows.last.read<String>('retrieval_keys_json'), '[]');
      expect(rows.last.readNullable<String>('target_kind'), isNull);
    });

    test(
      'v93 session lorebook evolution overlay has the session key',
      () async {
        final columns = await db
            .customSelect(
              "PRAGMA table_info('session_lorebook_evolution_rows')",
            )
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          containsAll([
            'chat_session_id',
            'lorebook_id',
            'entry_id',
            'base_content',
            'content',
            'content_hash',
          ]),
        );
      },
    );

    test('v96 canonicalizes every Studio preset block row', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_studio_v96_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        '''INSERT INTO studio_preset_rows
           (preset_id, name, blocks_json, agent_enabled_json,
            execution_mode, updated_at)
           VALUES (?, ?, ?, '{}', 'legacy', 1),
                  (?, ?, ?, '{}', 'legacy', 2),
                  (?, ?, ?, '{}', 'legacy', 3)''',
        [
          'legacy-context',
          'Legacy context',
          jsonEncode([
            {
              'id': 'memory-slot',
              'name': 'Memory source',
              'kind': 'memory',
              'content': 'ignored',
            },
          ]),
          'legacy-tracker',
          'Legacy tracker',
          jsonEncode([
            {
              'id': 'continuity_task',
              'kind': 'tracker_instruction',
              'content': 'Track continuity.',
            },
          ]),
          'malformed',
          'Malformed',
          '{not-json',
        ],
      );
      await seeded.customStatement('PRAGMA user_version = 95');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customSelect('SELECT 1').get();

      final rows = await upgraded
          .customSelect('SELECT preset_id, blocks_json FROM studio_preset_rows')
          .get();
      final byId = {
        for (final row in rows)
          row.read<String>('preset_id'): row.read<String>('blocks_json'),
      };
      final context = jsonDecode(byId['legacy-context']!) as List;
      expect(context.single['title'], 'Memory source');
      expect(context.single['type'], 'context');
      expect(context.single['contextSlot'], 'memory');
      expect(context.single, isNot(contains('kind')));
      final tracker = jsonDecode(byId['legacy-tracker']!) as List;
      expect(tracker.single['type'], 'instruction');
      expect(tracker.single['targetAgentId'], 'continuity');
      expect(byId['malformed'], '{not-json');

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test(
      'v95 retains the latest Card Rewriter debug result per writer stage',
      () async {
        final columns = await db
            .customSelect("PRAGMA table_info('card_evolution_debug_runs')")
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          containsAll([
            'session_id',
            'stage',
            'status',
            'model',
            'output',
            'attempts_json',
            'updated_at',
          ]),
        );
        final primaryKey = columns
            .where((row) => row.read<int>('pk') > 0)
            .map((row) => row.read<String>('name'));
        expect(primaryKey, containsAll(['session_id', 'stage']));
      },
    );

    test('v109 preserves the Responses opt-in through the v115 custom protocol '
        'migration and v110 adds the system-instruction toggle', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_sys_instruction_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'INSERT INTO api_configs (config_id, name, protocol, '
        'use_responses_api) VALUES (?, ?, ?, ?)',
        ['chat', 'Chat Completions', 'openai', 0],
      );
      await seeded.customStatement(
        'INSERT INTO api_configs (config_id, name, protocol, '
        'use_responses_api) VALUES (?, ?, ?, ?)',
        ['responses', 'Responses', 'openai', 1],
      );
      await seeded.customStatement(
        'INSERT INTO api_configs (config_id, name, protocol, '
        'use_responses_api) VALUES (?, ?, ?, ?)',
        ['gemini', 'Gemini', 'gemini', 1],
      );
      await seeded.customStatement(
        'ALTER TABLE api_configs DROP COLUMN use_system_instruction',
      );
      await seeded.customStatement('PRAGMA user_version = 108');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final rows = await upgraded
          .customSelect(
            'SELECT config_id, protocol, use_responses_api, '
            'use_system_instruction '
            'FROM api_configs ORDER BY config_id',
          )
          .get();
      final byId = {
        for (final row in rows)
          row.read<String>('config_id'): row.read<String>('protocol'),
      };

      expect(byId['chat'], 'custom_chat_completion');
      expect(byId['responses'], 'custom_chat_completion');
      expect(byId['gemini'], 'gemini');
      final responsesRow = rows.singleWhere(
        (row) => row.read<String>('config_id') == 'responses',
      );
      expect(responsesRow.read<bool>('use_responses_api'), isTrue);
      final chatRow = rows.singleWhere(
        (row) => row.read<String>('config_id') == 'chat',
      );
      expect(chatRow.read<bool>('use_responses_api'), isFalse);
      // Existing presets keep today's behaviour: the toggle defaults on.
      for (final row in rows) {
        expect(row.read<bool>('use_system_instruction'), isTrue);
      }

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v118 adds prompt post-processing with none for every config', () async {
      Future<Map<String, String>> upgradeWith(
        Map<String, Object> prefs,
        String? presetJson, {
        bool removeColumn = true,
      }) async {
        final file = File(
          '${Directory.systemTemp.path}/glaze_mig_ppp_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        addTearDown(() async {
          if (file.existsSync()) await file.delete();
        });

        final seeded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        await seeded.customSelect('SELECT 1').get();
        for (final config in const [
          ('custom', 'custom_chat_completion'),
          ('anthropic', 'anthropic'),
        ]) {
          await seeded.customStatement(
            'INSERT INTO api_configs (config_id, name, protocol) '
            'VALUES (?, ?, ?)',
            [config.$1, config.$1, config.$2],
          );
        }
        if (presetJson != null) {
          await seeded.customStatement(
            'INSERT INTO presets (preset_id, name, data_json) VALUES (?, ?, ?)',
            ['preset', 'Preset', presetJson],
          );
        }
        if (removeColumn) {
          await seeded.customStatement(
            'ALTER TABLE api_configs DROP COLUMN prompt_post_processing',
          );
        } else {
          await seeded.customStatement(
            "UPDATE api_configs SET prompt_post_processing = 'single' "
            "WHERE config_id = 'custom'",
          );
        }
        await seeded.customStatement('PRAGMA user_version = 117');
        await seeded.close();

        SharedPreferences.setMockInitialValues(prefs);
        final upgraded = AppDatabase.forTesting(
          NativeDatabase.createInBackground(file),
        );
        addTearDown(() async => upgraded.close());
        final rows = await upgraded
            .customSelect(
              'SELECT config_id, prompt_post_processing FROM api_configs',
            )
            .get();
        return {
          for (final row in rows)
            row.read<String>('config_id'): row.read<String>(
              'prompt_post_processing',
            ),
        };
      }

      // No preset selected.
      expect(await upgradeWith(const {}, null), {
        'custom': 'none',
        'anthropic': 'none',
      });

      // An inactive merge setting does not affect connection rows.
      expect(
        await upgradeWith(const {
          'activePresetId': 'preset',
        }, '{"id":"preset","name":"Preset","mergePrompts":false}'),
        {'custom': 'none', 'anthropic': 'none'},
      );

      // The legacy preset flag is intentionally not carried over, including
      // for custom connections.
      expect(
        await upgradeWith(const {
          'activePresetId': 'preset',
        }, '{"id":"preset","name":"Preset","mergePrompts":true}'),
        {'custom': 'none', 'anthropic': 'none'},
      );

      // A dangling preset id also cannot affect or block the upgrade.
      expect(await upgradeWith(const {'activePresetId': 'missing'}, null), {
        'custom': 'none',
        'anthropic': 'none',
      });

      // A partially/previously applied schema change is left intact rather
      // than trying to add the column again or rewriting existing choices.
      expect(await upgradeWith(const {}, null, removeColumn: false), {
        'custom': 'single',
        'anthropic': 'none',
      });
    });

    test('v119 lets card rewriter debug runs record a selection bail', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_selection_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('DROP TABLE card_evolution_debug_runs');
      // v118-shaped table: only model-backed stages, model always required.
      await seeded.customStatement('''
        CREATE TABLE card_evolution_debug_runs (
          session_id TEXT NOT NULL, stage TEXT NOT NULL,
          status TEXT NOT NULL, model TEXT NOT NULL, output TEXT NULL,
          attempts_json TEXT NOT NULL, updated_at INTEGER NOT NULL,
          PRIMARY KEY (session_id, stage),
          CHECK (session_id <> '' AND stage IN ('card', 'lorebook')
            AND status <> '' AND model <> '' AND attempts_json <> ''))
      ''');
      await seeded.customStatement(
        'INSERT INTO card_evolution_debug_runs (session_id, stage, status, '
        'model, output, attempts_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['session', 'card', 'ok', 'model-a', 'out', '[]', 10],
      );
      await expectLater(
        seeded.customStatement(
          'INSERT INTO card_evolution_debug_runs (session_id, stage, status, '
          'model, output, attempts_json, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          ['session', 'selection', 'notEligible', '', null, '[]', 20],
        ),
        throwsA(anything),
      );
      await seeded.customStatement('PRAGMA user_version = 118');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());

      // A writer that bails before resolving a model has no model name.
      await upgraded.customStatement(
        'INSERT INTO card_evolution_debug_runs (session_id, stage, status, '
        'model, output, attempts_json, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['session', 'selection', 'notEligible', '', null, '[{"a":1}]', 20],
      );
      final rows = await upgraded
          .customSelect(
            'SELECT stage, status, model FROM card_evolution_debug_runs '
            'ORDER BY stage',
          )
          .get();
      expect(rows.map((row) => row.read<String>('stage')).toList(), [
        'card',
        'selection',
      ]);
      // The pre-existing model diagnostic survives the table rebuild.
      expect(rows.first.read<String>('model'), 'model-a');
      expect(rows.last.read<String>('status'), 'notEligible');

      // Model stages still require a model name, and unknown stages stay out.
      await expectLater(
        upgraded.customStatement(
          'INSERT INTO card_evolution_debug_runs (session_id, stage, status, '
          'model, output, attempts_json, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          ['other', 'lorebook', 'ok', '', null, '[]', 30],
        ),
        throwsA(anything),
      );
      await expectLater(
        upgraded.customStatement(
          'INSERT INTO card_evolution_debug_runs (session_id, stage, status, '
          'model, output, attempts_json, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          ['other', 'bogus', 'ok', 'model-a', null, '[]', 30],
        ),
        throwsA(anything),
      );

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v120 adds the ledger debug journal to an older database', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_ledger_debug_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      // A v119 database predates the journal entirely.
      await seeded.customStatement('DROP TABLE ledger_debug_runs');
      await seeded.customStatement('PRAGMA user_version = 119');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());

      await upgraded.customStatement(
        'INSERT INTO ledger_debug_runs (id, session_id, kind, message_id, '
        'swipe_id, agent_swipe_id, status, model, parse_failure, '
        'rejection_reason, rejected_ops_json, repair_attempted, '
        'repair_failure, response_text, repair_response_text, attempts_json, '
        'error, ops_applied, elapsed_ms, prompt_chars, response_chars, '
        'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
        '?, ?, ?, ?, ?, ?)',
        [
          'ledger-debug-1',
          'session',
          'normal',
          'message',
          0,
          0,
          'error',
          'model-a',
          'malformedJson',
          'malformed JSON: unexpected end of input',
          '["op[0] rejected"]',
          1,
          'none',
          'raw',
          'repaired',
          '[]',
          'parse failed',
          0,
          1200,
          900,
          400,
          10,
        ],
      );
      final rows = await upgraded
          .customSelect(
            'SELECT kind, parse_failure, repair_attempted, rejected_ops_json '
            'FROM ledger_debug_runs',
          )
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.read<String>('kind'), 'normal');
      expect(rows.single.read<String>('parse_failure'), 'malformedJson');
      expect(rows.single.read<int>('repair_attempted'), 1);
      expect(
        rows.single.read<String>('rejected_ops_json'),
        '["op[0] rejected"]',
      );

      // Only the two real Ledger call sites may write to the journal.
      await expectLater(
        upgraded.customStatement(
          'INSERT INTO ledger_debug_runs (id, session_id, kind, status, '
          'created_at) VALUES (?, ?, ?, ?, ?)',
          ['ledger-debug-2', 'session', 'bogus', 'ok', 20],
        ),
        throwsA(anything),
      );

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v121 adds the session canon timeline foundation', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_session_canon_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      for (final table in const [
        'session_lorebook_embedding_job_rows',
        'session_lorebook_revision_rows',
        'session_canon_checkpoint_rows',
      ]) {
        await seeded.customStatement('DROP TABLE $table');
      }
      await seeded.customStatement('PRAGMA user_version = 120');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());

      final tables = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN "
            "('session_canon_checkpoint_rows', "
            "'session_lorebook_revision_rows', "
            "'session_lorebook_embedding_job_rows')",
          )
          .get();
      expect(tables.map((row) => row.read<String>('name')).toSet(), {
        'session_canon_checkpoint_rows',
        'session_lorebook_revision_rows',
        'session_lorebook_embedding_job_rows',
      });
      final integrity = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE name IN "
            "('session_canon_checkpoint_rows_no_update', "
            "'session_lorebook_revision_rows_no_update', "
            "'idx_session_lorebook_embedding_job_active')",
          )
          .get();
      expect(integrity.map((row) => row.read<String>('name')).toSet(), {
        'session_canon_checkpoint_rows_no_update',
        'session_lorebook_revision_rows_no_update',
        'idx_session_lorebook_embedding_job_active',
      });

      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v122 adds the embedding request rate limit', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_embedding_rpm_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        "INSERT INTO api_configs (config_id, name) VALUES ('existing', 'Existing')",
      );
      await seeded.customStatement(
        'ALTER TABLE api_configs DROP COLUMN embedding_requests_per_minute',
      );
      await seeded.customStatement('PRAGMA user_version = 121');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final row = await upgraded
          .customSelect(
            'SELECT embedding_requests_per_minute FROM api_configs '
            "WHERE config_id = 'existing'",
          )
          .getSingle();

      expect(row.read<int>('embedding_requests_per_minute'), 50);
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 122);
    });

    test('v111 resolves the retired session_id_mode default', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_session_id_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      for (final row in const [
        ('or-protocol', 'openrouter', '', 'openrouter'),
        ('or-endpoint', 'openai', 'https://openrouter.ai/api/v1', 'openrouter'),
        ('plain', 'openai', 'https://api.openai.com/v1', 'openrouter'),
        ('explicit-on', 'openai', 'https://api.openai.com/v1', 'always'),
        ('explicit-off', 'openrouter', '', 'off'),
      ]) {
        await seeded.customStatement(
          'INSERT INTO api_configs (config_id, name, protocol, endpoint, '
          'session_id_mode) VALUES (?, ?, ?, ?, ?)',
          [row.$1, row.$1, row.$2, row.$3, row.$4],
        );
      }
      await seeded.customStatement('PRAGMA user_version = 110');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final rows = await upgraded
          .customSelect('SELECT config_id, session_id_mode FROM api_configs')
          .get();
      final byId = {
        for (final row in rows)
          row.read<String>('config_id'): row.read<String>('session_id_mode'),
      };

      // The retired default meant "only openrouter.ai" — preserved either way.
      expect(byId['or-protocol'], 'always');
      expect(byId['or-endpoint'], 'always');
      expect(byId['plain'], 'off');
      // Explicit choices are left alone.
      expect(byId['explicit-on'], 'always');
      expect(byId['explicit-off'], 'off');
    });

    test('v112 renames the system-instruction column', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_sysinstr_rename_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });

      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'INSERT INTO api_configs (config_id, name, use_system_instruction) '
        'VALUES (?, ?, ?)',
        ['legacy', 'Legacy', 0],
      );
      // Recreate the pre-rename shape the branch shipped at v110.
      await seeded.customStatement(
        'ALTER TABLE api_configs RENAME COLUMN use_system_instruction '
        'TO gemini_use_system_instruction',
      );
      await seeded.customStatement('PRAGMA user_version = 111');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final row = await upgraded
          .customSelect(
            'SELECT use_system_instruction FROM api_configs '
            'WHERE config_id = ?',
            variables: [Variable.withString('legacy')],
          )
          .getSingle();

      // The stored choice survives the rename.
      expect(row.read<bool>('use_system_instruction'), isFalse);
    });

    test('v113 migrates legacy observation evidence into one cluster', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_observation_clusters_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement(
        'INSERT INTO card_evolution_observations '
        '(id, session_id, character_id, run_ordinal, semantic_scope_key, '
        'observed_change, evidence_message_ids, confidence, status, '
        'first_seen_run, repeat_count, created_at, updated_at) '
        'VALUES (?, ?, ?, 1, ?, ?, ?, 0.9, ?, 1, ?, 1, 1)',
        [
          'gilda',
          'session',
          'gilda-character',
          'relationship:gilda',
          'Gilda trusts the user',
          '["m1","m2","m1",""]',
          'active',
          7,
        ],
      );
      await seeded.customStatement(
        'INSERT INTO card_evolution_observations '
        '(id, session_id, character_id, run_ordinal, semantic_scope_key, '
        'observed_change, evidence_message_ids, confidence, status, '
        'first_seen_run, repeat_count, created_at, updated_at) '
        "VALUES ('bad', 'session', 'gilda-character', 1, 'bad', 'Bad', "
        "'not-json', 0.5, 'active', 1, 4, 1, 1)",
      );
      await seeded.customStatement(
        'ALTER TABLE card_evolution_observations '
        'DROP COLUMN evidence_clusters_json',
      );
      await seeded.customStatement('PRAGMA user_version = 112');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final rows = await upgraded
          .customSelect(
            'SELECT id, evidence_message_ids, evidence_clusters_json, repeat_count, '
            'status, retrieval_keys_json, target_kind '
            'FROM card_evolution_observations ORDER BY id',
          )
          .get();
      final gilda = rows.singleWhere(
        (row) => row.read<String>('id') == 'gilda',
      );
      expect(gilda.read<String>('evidence_message_ids'), '["m1","m2"]');
      expect(gilda.read<String>('evidence_clusters_json'), '[["m1","m2"]]');
      expect(gilda.read<int>('repeat_count'), 1);
      expect(gilda.read<String>('status'), 'active');
      expect(gilda.read<String>('retrieval_keys_json'), '[]');
      expect(gilda.readNullable<String>('target_kind'), isNull);
      final bad = rows.singleWhere((row) => row.read<String>('id') == 'bad');
      expect(bad.read<String>('evidence_message_ids'), '[]');
      expect(bad.read<String>('evidence_clusters_json'), '[]');
      expect(bad.read<int>('repeat_count'), 1);
    });

    test('v114 allows a later revision to reuse an earlier hash', () async {
      final file = File(
        '${Directory.systemTemp.path}/glaze_mig_revision_hash_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      final seeded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      await seeded.customSelect('SELECT 1').get();
      await seeded.customStatement('DROP INDEX idx_character_revision_hash');
      await seeded.customStatement(
        'CREATE UNIQUE INDEX character_revision_rows_character_id_revision_hash '
        'ON character_revision_rows (character_id, revision_hash)',
      );
      await seeded.customStatement(
        'INSERT INTO character_revision_rows '
        '(character_id, revision, revision_hash, parent_revision_hash, snapshot_json) '
        "VALUES ('c', 1, 'hash-a', '', '{\"description\":\"a\"}'), "
        "('c', 2, 'hash-b', 'hash-a', '{\"description\":\"b\"}')",
      );
      await seeded.customStatement('PRAGMA user_version = 113');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      await upgraded.customStatement(
        'INSERT INTO character_revision_rows '
        '(character_id, revision, revision_hash, parent_revision_hash, snapshot_json) '
        "VALUES ('c', 3, 'hash-a', 'hash-b', '{\"description\":\"a\"}')",
      );
      final rows = await upgraded
          .customSelect(
            'SELECT revision, revision_hash, parent_revision_hash '
            'FROM character_revision_rows ORDER BY revision',
          )
          .get();
      expect(rows.map((row) => row.read<int>('revision')), [1, 2, 3]);
      expect(rows.last.read<String>('revision_hash'), 'hash-a');
      expect(rows.last.read<String>('parent_revision_hash'), 'hash-b');
      final indexes = await upgraded
          .customSelect("PRAGMA index_list('character_revision_rows')")
          .get();
      expect(
        indexes
            .singleWhere(
              (row) =>
                  row.read<String>('name') == 'idx_character_revision_hash',
            )
            .read<int>('unique'),
        0,
      );
    });
  });
}

Map<String, dynamic> _minimalBackup() => {
  'keyvalue': <String, dynamic>{},
  'localStorage': <String, dynamic>{},
  'characters': <dynamic>[],
  'personas': <dynamic>[],
};
