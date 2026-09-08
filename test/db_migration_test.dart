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
      expect(version, 81);
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
        expect(version.first.read<int>('user_version'), 81);
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
      expect(version.read<int>('user_version'), 81);
    });

    test('current schema includes atomic character fact tables', () async {
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 81);

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
      expect(version.read<int>('user_version'), 81);
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
      expect(version.read<int>('user_version'), 81);
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
      expect(version.read<int>('user_version'), 81);
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
      await seeded.customStatement(
        'DROP INDEX idx_embeddings_source_type_id',
      );
      await seeded.customStatement('PRAGMA user_version = 80');
      await seeded.close();

      final upgraded = AppDatabase.forTesting(
        NativeDatabase.createInBackground(file),
      );
      addTearDown(() async => upgraded.close());
      final indexes = await upgraded.customSelect(
        "PRAGMA index_list('embeddings')",
      ).get();

      expect(
        indexes.map((row) => row.read<String>('name')),
        contains('idx_embeddings_source_type_id'),
      );
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 81);
    });

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
        'INSERT INTO studio_preset_rows '
        '(preset_id, name, blocks_json, updated_at) VALUES (?, ?, ?, ?)',
        ['default', 'Default Studio Preset', jsonEncode(staleBlocks), 1],
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
      expect(version.read<int>('user_version'), 81);
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
      expect(version.read<int>('user_version'), 81);
      final check = await upgraded.customSelect('PRAGMA integrity_check').get();
      expect(check.single.read<String>('integrity_check'), 'ok');
    });

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
      'v66 removes agentic micro-memory without rewriting stored presets',
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
        expect(presets['legacy-write-loop'], contains('writeMemory'));
        expect(presets['legacy-write-loop'], contains('{{existingBlock}}'));
        expect(
          presets['custom-tracker-loop'],
          contains('Track only weather changes.'),
        );
      },
    );

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
  });
}

Map<String, dynamic> _minimalBackup() => {
  'keyvalue': <String, dynamic>{},
  'localStorage': <String, dynamic>{},
  'characters': <dynamic>[],
  'personas': <dynamic>[],
};
