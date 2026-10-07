// Generates `glaze_v079_0.7.0.db` with the v0.7.0 code itself, so the
// fixture carries that release's real schema. It compiles only against the
// v0.7.0 tag (hence the analyzer exclusion of this directory):
//
//   git worktree add /tmp/glaze_v070 v0.7.0
//   cd /tmp/glaze_v070 && touch .env && flutter pub get
//   dart run build_runner build --delete-conflicting-outputs
//   cp <repo>/test/fixtures/db/generate_v079_0.7.0.dart \
//     test/generate_v079_test.dart
//   FIXTURE_OUT=<repo>/test/fixtures/db/glaze_v079_0.7.0.db \
//     flutter test test/generate_v079_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/db/repositories/persona_repo.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

const _now = 1759000000;

void main() {
  test('generate v79 fixture', () async {
    final out = File(Platform.environment['FIXTURE_OUT']!);
    if (out.existsSync()) out.deleteSync();
    final db = AppDatabase.forTesting(NativeDatabase(out));

    await ApiConfigRepo(db).put(
      const ApiConfig(
        id: 'api_main',
        name: 'OpenRouter',
        providerId: 'openrouter',
        protocol: 'openrouter',
        endpoint: 'https://openrouter.ai/api/v1',
        apiKey: 'sk-test',
        model: 'anthropic/claude-sonnet',
        requestReasoning: true,
        cacheControlTtl: '5min',
      ),
    );
    await ApiConfigRepo(db).put(
      const ApiConfig(
        id: 'api_local',
        name: 'Local',
        endpoint: 'http://127.0.0.1:5001/v1',
        model: 'local',
        sessionIdMode: 'openrouter',
        embeddingEnabled: true,
        embeddingUseSame: false,
        embeddingEndpoint: 'http://127.0.0.1:5001/v1',
        embeddingModel: 'nomic-embed',
      ),
    );

    await PresetRepo(db).put(
      Preset(
        id: 'default_chat',
        name: 'Default Chat',
        blocks: const [
          PresetBlock(
            id: 'main',
            name: 'Main Prompt',
            role: 'system',
            content: "Write {{char}}'s next reply.",
          ),
          PresetBlock(
            id: 'chat_history',
            name: 'Chat History',
            role: 'system',
            content: '',
            isStatic: true,
          ),
        ],
        regexes: const [
          PresetRegex(id: 'rx1', name: 'Trim', regex: r'\s+$'),
        ],
        createdAt: _now,
      ),
    );

    await PersonaRepo(db).put(
      const Persona(id: 'persona_1', name: 'User', prompt: 'A traveller.'),
    );

    final characters = CharacterRepo(db);
    await characters.put(
      const Character(
        id: 'char_alice',
        name: 'Alice',
        description: 'A curious girl.',
        firstMes: 'Hello there!',
        tags: ['fantasy'],
        alternateGreetings: ['Hi!'],
        updatedAt: _now,
        createdAt: _now,
        variantGroupId: 'char_alice',
        extensions: {
          'world': 'Wonderland',
          'depth_prompt': {'prompt': 'Stay curious.', 'depth': 4},
        },
      ),
    );
    await characters.put(
      const Character(
        id: 'char_alice_alt',
        name: 'Alice',
        variantGroupId: 'char_alice',
        variantName: 'Older',
        variantOrder: 1,
        updatedAt: _now,
        createdAt: _now,
      ),
    );
    await characters.put(
      const Character(
        id: 'char_bob',
        name: 'Bob',
        fav: true,
        hidden: true,
        updatedAt: _now,
        createdAt: _now,
        variantGroupId: 'char_bob',
      ),
    );

    ChatMessage msg(String id, String role, String content) => ChatMessage(
      id: id,
      role: role,
      content: content,
      swipes: [content],
      timestamp: _now,
    );
    final chats = ChatRepo(db);
    await chats.put(
      ChatSession(
        id: 'char_alice_0',
        characterId: 'char_alice',
        sessionIndex: 0,
        updatedAt: _now,
        sessionVars: const {'mood': 'happy'},
        messages: [
          msg('m0', 'assistant', 'Hello there!'),
          msg('m1', 'user', 'Who are you?'),
          msg('m2', 'assistant', 'I am Alice.').copyWith(
            swipes: ['I am Alice.', 'Alice, nice to meet you.'],
            agentSwipes: const [
              AgentSwipe(kind: 'cleaned', content: 'I am Alice.', parentSwipeId: 0),
            ],
            agentSwipeId: 1,
          ),
        ],
      ),
    );
    await chats.put(
      ChatSession(
        id: 'char_bob_0',
        characterId: 'char_bob',
        sessionIndex: 0,
        updatedAt: _now,
        messages: [msg('b0', 'assistant', 'Yo.')],
      ),
    );

    await LorebookRepo(db).put(
      const Lorebook(
        id: 'lore_world',
        name: 'Wonderland',
        activationScope: 'character',
        activationTargetId: 'char_alice',
        updatedAt: _now,
        entries: [
          LorebookEntry(
            id: 'e1',
            keys: ['rabbit'],
            content: 'The White Rabbit is always late.',
          ),
          LorebookEntry(id: 'e2', constant: true, content: 'Tea time.'),
        ],
      ),
    );
    await LorebookRepo(db).put(
      const Lorebook(id: 'lore_global', name: 'Global', updatedAt: _now),
    );

    await StudioPresetRepo(db).upsert(
      const StudioPreset(
        id: 'default',
        name: 'Default Studio Preset',
        updatedAt: _now,
        agentEnabled: {'continuity': true, 'narrative': false},
        blocks: [
          StudioPresetBlock(
            id: 'final_system',
            title: 'Final',
            content: 'Write the reply.',
            section: 'final',
          ),
          StudioPresetBlock(
            id: 'writeloop_system',
            title: 'Write loop',
            content: 'Legacy write loop.',
            section: 'ledger',
            order: 5,
          ),
          StudioPresetBlock(
            id: 'cleaner_beauty',
            title: 'Beauty',
            content: 'Style it.',
            section: 'cleaner',
            order: 99,
          ),
        ],
      ),
    );
    await StudioConfigRepo(db).upsert(
      const StudioConfig(
        sessionId: 'char_alice_0',
        enabled: true,
        expensiveApiConfigId: 'api_main',
        cheapApiConfigId: 'api_local',
        cleanerApiConfigId: 'api_local',
        broadcastBlocks: ['[Block: Language]\nWrite in English.'],
        agents: [
          StudioAgent(id: 'continuity', name: 'Continuity', order: 1),
          StudioAgent(id: 'final', name: 'Final', order: 2),
        ],
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await StudioConfigRepo(db).upsert(
      const StudioConfig(
        sessionId: 'profile_shared',
        profileId: 'profile_shared',
        profileName: 'Shared profile',
        agents: [StudioAgent(id: 'final', name: 'Final')],
        createdAt: _now,
        updatedAt: _now,
      ),
    );

    const tracker = Tracker(
      sessionId: 'char_alice_0',
      name: 'location',
      value: 'Garden',
      provenance: 'studio_ledger',
      updatedAt: _now,
    );
    await TrackerRepo(db).upsert(tracker);
    await TrackerSnapshotRepo(db).upsertTrackers(
      sessionId: 'char_alice_0',
      messageId: 'm2',
      swipeId: 0,
      agentSwipeId: 1,
      trackers: const [tracker],
      committed: true,
    );

    final statements = <String>[
      "INSERT INTO character_folders (folder_id, name, sort_order, created_at, updated_at) VALUES ('folder_1', 'Favs', 0, $_now, $_now)",
      "INSERT INTO character_folder_members (folder_id, char_id, added_at) VALUES ('folder_1', 'char_alice', $_now)",
      "INSERT INTO chat_summaries (session_id, content, enabled, message_count, updated_at) VALUES ('char_alice_0', 'Alice met the user.', 1, 3, $_now)",
      "INSERT INTO extension_presets (id, name, config_json, created_at) VALUES ('ext_1', 'Status', '{\"blocks\":[]}', $_now)",
      "INSERT INTO info_blocks (id, session_id, message_id, swipe_id, agent_swipe_id, block_id, block_name, block_type, content, created_at, \"order\", status) VALUES ('ib_1', 'char_alice_0', 'm2', 0, 1, 'status', 'Status', 'html', '<b>ok</b>', $_now, 0, 'done')",
      "INSERT INTO embeddings (entry_id, source_type, source_id, vectors_blob, text_hash, updated_at) VALUES ('lore_world_e1', 'lorebook_entry', 'lore_world', x'0000803f00000040', 'hash', $_now)",
      "INSERT INTO memory_book_rows (session_id, entries_json, pending_drafts_json, settings_json, last_processed_message_count, updated_at) VALUES ('char_alice_0', ${_q(jsonEncode([
        {'id': 'mem_1', 'title': 'Meeting', 'content': 'Alice met the user.', 'keys': ['meeting'], 'messageIds': ['m1', 'm2'], 'source': 'manual', 'enabled': true},
        {'id': 'mem_2', 'title': 'Agentic', 'content': 'Retired agentic fact.', 'keys': [], 'messageIds': ['m2'], 'source': 'agentic', 'enabled': true},
      ]))}, '[]', '{\"enabled\":true}', 3, $_now)",
      "INSERT INTO memory_catalog_rows (id, chat_session_id, memory_entry_id, title, created_at, updated_at) VALUES ('cat_1', 'char_alice_0', 'mem_1', 'Meeting', $_now, $_now)",
      "INSERT INTO memory_entity_rows (id, chat_session_id, memory_entry_id, name, created_at, updated_at) VALUES ('ent_1', 'char_alice_0', 'mem_1', 'Alice', $_now, $_now)",
      "INSERT INTO memory_salience_rows (id, chat_session_id, memory_entry_id, score, scored_at, created_at) VALUES ('sal_1', 'char_alice_0', 'mem_1', 0.7, $_now, $_now)",
      "INSERT INTO memory_cadence_rows (chat_session_id, assistant_messages_since_last_run, last_run_message_index, last_run_at) VALUES ('char_alice_0', 1, 2, $_now)",
      "INSERT INTO memory_consolidation_rows (id, chat_session_id, title, summary, created_at, updated_at) VALUES ('con_1', 'char_alice_0', 'Arc', 'They met.', $_now, $_now)",
      "INSERT INTO character_knowledge_fact_rows (id, chat_session_id, knower_key, knower_name, subject_key, subject_name, fact_class, predicate, object, epistemic_state, confidence, source_message_id, lifecycle, created_at, updated_at) VALUES ('fact_1', 'char_alice_0', 'alice', 'Alice', 'user', 'User', 'relationship', 'met', 'in the garden', 'knows', 0.9, 'm2', 'accepted', $_now, $_now)",
      "INSERT INTO character_session_baseline_rows (chat_session_id, character_id, baseline_card_json, baseline_hash, created_at, updated_at) VALUES ('char_alice_0', 'char_alice', '{\"name\":\"Alice\"}', 'h1', $_now, $_now)",
      "INSERT INTO ledger_reconciliation_checkpoints (session_id, start_message_id, end_message_id, message_ids_json, range_hash, reviewed_at) VALUES ('char_alice_0', 'm0', 'm2', '[\"m0\",\"m1\",\"m2\"]', 'rh', $_now)",
      "INSERT INTO ledger_reconciliation_cleanup_journals (session_id, endpoint_message_id, message_ids_json, before_images_json, created_at) VALUES ('char_alice_0', 'm2', '[\"m2\"]', '[]', $_now)",
    ];
    for (final sql in statements) {
      await db.customStatement(sql);
    }

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 79);
    await db.customStatement('VACUUM');
    await db.close();
  });
}

String _q(String s) => "'${s.replaceAll("'", "''")}'";
