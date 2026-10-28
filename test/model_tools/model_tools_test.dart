import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/tools/llm_tool_call.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/model_tools/character_tool_proposal.dart';
import 'package:glaze_flutter/features/model_tools/model_tool.dart';
import 'package:glaze_flutter/features/model_tools/model_tool_runner.dart';
import 'package:glaze_flutter/features/settings/api_config_draft.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _refProvider = Provider<Ref>((ref) => ref);

ApiConfig _config({
  bool toolCalling = true,
  String protocol = LlmProtocol.openai,
  List<String> disabled = const [],
}) => ApiConfig(
  id: 'c',
  protocol: protocol,
  toolCalling: toolCalling,
  disabledToolGroups: disabled,
);

LlmToolTurn _turn(String name, Map<String, dynamic> args) => LlmToolTurn(
  calls: [LlmToolCall(id: 'call_1', name: name, rawArguments: jsonEncode(args))],
);

Map<String, dynamic> _decode(Map<String, String> results) =>
    jsonDecode(results['call_1']!) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelToolset.forConfig', () {
    List<String> names(ApiConfig c) => [
      for (final t in ModelToolset.forConfig(c).tools) t.name,
    ];

    test('offers nothing while tool calling is off', () {
      expect(names(_config(toolCalling: false)), isEmpty);
    });

    test('offers nothing on a protocol that cannot report calls', () {
      expect(names(_config(protocol: LlmProtocol.gemini)), isEmpty);
      expect(names(_config(protocol: LlmProtocol.openaiResponses)), isEmpty);
    });

    test('reading rides along with any enabled write group', () {
      expect(names(_config()), [
        'glaze_list_characters',
        'glaze_get_character',
        'glaze_create_character',
        'glaze_update_character',
      ]);
      expect(names(_config(disabled: ['characters_edit'])), [
        'glaze_list_characters',
        'glaze_get_character',
        'glaze_create_character',
      ]);
      expect(
        names(_config(disabled: ['characters_create', 'characters_edit'])),
        isEmpty,
      );
    });
  });

  test('the API editor clears tool calling where the protocol has none', () {
    final gemini = ApiConfigDraft.normalizeValues(
      _config(protocol: LlmProtocol.gemini),
    );
    expect(gemini.toolCalling, isFalse);
    final anthropic = ApiConfigDraft.normalizeValues(
      _config(protocol: LlmProtocol.anthropic),
    );
    expect(anthropic.toolCalling, isTrue);
  });

  group('running calls', () {
    late AppDatabase db;
    late ProviderContainer container;
    late Directory images;
    final proposals = <CharacterToolProposal>[];
    bool? answer = true;

    ModelToolContext context({bool aborted = false}) => ModelToolContext(
      ref: container.read(_refProvider),
      charId: 'ann',
      isAborted: () => aborted,
      confirm: (p) async {
        proposals.add(p);
        return answer;
      },
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      images = await Directory.systemTemp.createTemp('model_tools_test');
      container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          imageStorageProvider.overrideWith(
            (ref) async => ImageStorageService(images.path),
          ),
        ],
      );
      proposals.clear();
      answer = true;
      await container
          .read(characterRepoProvider)
          .put(
            const Character(
              id: 'ann',
              name: 'Ann',
              description: 'A knight.',
              tags: ['fantasy'],
              updatedAt: 2,
            ),
          );
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'bob', name: 'Bob', updatedAt: 1));
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      await images.delete(recursive: true);
    });

    final toolset = ModelToolset.forConfig(_config());

    test('list marks the current chat and searches tags', () async {
      final result = _decode(
        await toolset.run(
          _turn('glaze_list_characters', {'query': 'FANTASY'}),
          context(),
        ),
      );
      expect(result['ok'], isTrue);
      final characters = (result['result'] as Map)['characters'] as List;
      expect(characters.single['id'], 'ann');
      expect(characters.single['isCurrentChat'], isTrue);
    });

    test('get without an id reads the current chat character', () async {
      final result = _decode(
        await toolset.run(_turn('glaze_get_character', {}), context()),
      );
      expect((result['result'] as Map)['name'], 'Ann');
      expect((result['result'] as Map)['first_mes'], '');
    });

    test('update shows only the fields that change, then saves them', () async {
      final result = _decode(
        await toolset.run(
          _turn('glaze_update_character', {
            'id': 'ann',
            'changes': {
              'description': 'A knight.',
              'personality': 'Brave',
              'tags': ['fantasy', 'knight'],
            },
          }),
          context(),
        ),
      );
      expect(result['ok'], isTrue, reason: '$result');
      expect((result['result'] as Map)['updatedFields'], [
        'personality',
        'tags',
      ]);
      final proposal = proposals.single;
      expect(proposal.kind, CharacterProposalKind.update);
      expect(proposal.changes.map((c) => c.field.key), ['personality', 'tags']);
      expect(proposal.changes.first.before, '');

      final stored = await container.read(characterRepoProvider).getById('ann');
      expect(stored!.personality, 'Brave');
      expect(stored.tags, ['fantasy', 'knight']);
      expect(stored.description, 'A knight.');
    });

    test('a declined update leaves the card alone', () async {
      answer = false;
      final result = _decode(
        await toolset.run(
          _turn('glaze_update_character', {
            'id': 'ann',
            'changes': {'name': 'Anna'},
          }),
          context(),
        ),
      );
      expect(result['ok'], isFalse);
      expect((result['error'] as Map)['code'], 'user_rejected');
      final stored = await container.read(characterRepoProvider).getById('ann');
      expect(stored!.name, 'Ann');
    });

    test('no way to ask is reported apart from a refusal', () async {
      answer = null;
      final result = _decode(
        await toolset.run(
          _turn('glaze_update_character', {
            'id': 'ann',
            'changes': {'name': 'Anna'},
          }),
          context(),
        ),
      );
      expect((result['error'] as Map)['code'], 'unavailable');
    });

    test('a declined create never reaches the importer', () async {
      answer = false;
      final result = _decode(
        await toolset.run(
          _turn('glaze_create_character', {
            'character': {
              'name': 'Cid',
              'description': 'A smith.',
              'first_mes': 'Hello.',
              'character_book': {
                'name': 'Forge',
                'entries': [
                  {
                    'keys': ['forge'],
                    'content': 'Hot.',
                  },
                ],
              },
            },
          }),
          context(),
        ),
      );
      expect((result['error'] as Map)['code'], 'user_rejected');
      final proposal = proposals.single;
      expect(proposal.kind, CharacterProposalKind.create);
      expect(proposal.characterName, 'Cid');
      expect(proposal.lorebookEntryCount, 1);
      expect(proposal.lorebookName, 'Forge');
      final all = await container.read(characterRepoProvider).getAll();
      expect(all.map((c) => c.name), isNot(contains('Cid')));
    });

    test('an approved create goes through the import path, lorebook included', () async {
      final result = _decode(
        await toolset.run(
          _turn('glaze_create_character', {
            'character': {
              'name': 'Cid',
              'description': 'A smith.',
              'first_mes': 'Hello.',
              'alternate_greetings': ['Hi again.'],
              'character_book': {
                'name': 'Forge',
                'entries': [
                  {
                    'keys': ['forge'],
                    'content': 'Hot.',
                  },
                ],
              },
            },
          }),
          context(),
        ),
      );
      expect(result['ok'], isTrue, reason: '$result');
      final created = result['result'] as Map;
      final stored = await container
          .read(characterRepoProvider)
          .getById(created['characterId'] as String);
      expect(stored!.name, 'Cid');
      expect(stored.firstMes, 'Hello.');
      expect(stored.alternateGreetings, ['Hi again.']);
      expect(created['lorebookId'], isNotNull);
      final books = await container.read(lorebooksProvider.future);
      final book = books.singleWhere((b) => b.id == created['lorebookId']);
      expect(book.entries.single.content, 'Hot.');
    });

    test('invalid arguments name the offending path', () async {
      final result = _decode(
        await toolset.run(
          _turn('glaze_update_character', {
            'id': 'ann',
            'changes': {'tags': 'not a list'},
          }),
          context(),
        ),
      );
      final error = result['error'] as Map;
      expect(error['code'], 'invalid_arguments');
      expect((error['details'] as Map)['path'], 'changes.tags');
      expect(proposals, isEmpty);
    });

    test('unknown fields, ids and tools are errors, not crashes', () async {
      final unknownField = _decode(
        await toolset.run(
          _turn('glaze_update_character', {
            'id': 'ann',
            'changes': {'avatar': 'x'},
          }),
          context(),
        ),
      );
      expect((unknownField['error'] as Map)['code'], 'invalid_arguments');

      final missing = _decode(
        await toolset.run(_turn('glaze_get_character', {'id': 'nope'}), context()),
      );
      expect((missing['error'] as Map)['code'], 'resource_not_found');

      final unknownTool = _decode(
        await toolset.run(_turn('glaze_delete_everything', {}), context()),
      );
      expect((unknownTool['error'] as Map)['code'], 'unknown_tool');
    });

    test('calls after a stop are answered as cancelled without running', () async {
      final result = _decode(
        await toolset.run(
          _turn('glaze_update_character', {
            'id': 'ann',
            'changes': {'name': 'Anna'},
          }),
          context(aborted: true),
        ),
      );
      expect((result['error'] as Map)['code'], 'cancelled');
      expect(proposals, isEmpty);
    });
  });
}
