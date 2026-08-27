import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/backup_cancel.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/backup/js_api_config_importer.dart';
import 'package:glaze_flutter/core/services/backup/js_lorebook_importer.dart';
import 'package:glaze_flutter/core/services/backup/st_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

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

  group('JsApiConfigImporter', () {
    test('imports simple API config from kv/ls', () async {
      final importer = JsApiConfigImporter(db, imageStorage);

      final kv = <String, dynamic>{};
      final ls = <String, dynamic>{
        'api-endpoint': 'https://api.openai.com/v1',
        'api-key': 'sk-test123',
        'api-model': 'gpt-4',
        'api-max-tokens': '4096',
        'api-context': '16000',
        'gz_api_temp': '0.8',
        'gz_api_topp': '0.95',
      };

      await importer.importApiConfigs(kv, ls);

      final configs = await db.select(db.apiConfigs).get();
      expect(configs.length, 1);
      final c = configs.first;
      expect(c.name, equals('Default'));
      expect(c.endpoint, equals('https://api.openai.com/v1/chat/completions'));
      expect(c.apiKey, equals('sk-test123'));
      expect(c.model, equals('gpt-4'));
      expect(c.maxTokens, equals(4096));
      expect(c.contextSize, equals(16000));
      expect(c.temperature, closeTo(0.8, 0.01));
      expect(c.topP, closeTo(0.95, 0.01));
    });

    test('imports provider profiles with service profile map', () async {
      final importer = JsApiConfigImporter(db, imageStorage);

      final profilesJson = jsonEncode([
        {
          'id': 'llm1',
          'name': 'My LLM',
          'endpoint': 'https://llm.example.com',
          'apiKey': 'sk-llm',
          'model': 'claude-3',
          'max_tokens': 8000,
          'context': 32000,
          'temp': 0.7,
          'topp': 0.9,
        },
        {
          'id': 'emb1',
          'name': 'My Embedding',
          'endpoint': 'https://emb.example.com',
          'apiKey': 'sk-emb',
          'model': 'text-embedding-3',
          'mode': 'embedding',
        },
      ]);

      final spmJson = jsonEncode({
        'llm': {'profileId': 'llm1'},
        'embedding': {'profileId': 'emb1', 'useSameAsLLM': false},
      });

      final kv = <String, dynamic>{};
      final ls = <String, dynamic>{
        'gz_provider_profiles': profilesJson,
        'gz_service_profile_map': spmJson,
      };

      await importer.importApiConfigs(kv, ls);

      final configs = await db.select(db.apiConfigs).get();
      expect(configs.length, 1);
      final c = configs.first;
      expect(c.configId, equals('llm1'));
      expect(c.name, equals('My LLM'));
      expect(c.endpoint, equals('https://llm.example.com/v1/chat/completions'));
      expect(c.embeddingEnabled, isTrue);
      expect(c.embeddingUseSame, isFalse);
      expect(
        c.embeddingEndpoint,
        equals('https://emb.example.com/v1/embeddings'),
      );
      expect(c.embeddingApiKey, equals('sk-emb'));
      expect(c.embeddingModel, equals('text-embedding-3'));
    });

    test('imports presets from connection presets key', () async {
      final importer = JsApiConfigImporter(db, imageStorage);

      final presetsJson = jsonEncode([
        {
          'id': 'preset1',
          'name': 'Preset One',
          'endpoint': 'https://api.example.com',
          'apiKey': 'sk-p1',
          'model': 'gpt-4o',
        },
        {
          'id': 'preset2',
          'name': 'Preset Two',
          'endpoint': 'https://api2.example.com',
          'apiKey': 'sk-p2',
          'model': 'gpt-4o-mini',
        },
      ]);

      final kv = <String, dynamic>{'gz_api_connection_presets': presetsJson};
      final ls = <String, dynamic>{};

      await importer.importApiConfigs(kv, ls);

      final configs = await db.select(db.apiConfigs).get();
      expect(configs.length, 2);
      final names = configs.map((c) => c.name).toSet();
      expect(names, containsAll(['Preset One', 'Preset Two']));
    });

    test('skips embedding-only presets', () async {
      final importer = JsApiConfigImporter(db, imageStorage);

      final presetsJson = jsonEncode([
        {
          'id': 'emb_only',
          'name': 'Embedding Only',
          'endpoint': 'https://emb.example.com',
          'apiKey': 'sk-emb',
          'model': 'text-embedding-3',
          'mode': 'embedding',
        },
      ]);

      final kv = <String, dynamic>{'gz_api_connection_presets': presetsJson};
      final ls = <String, dynamic>{};

      await importer.importApiConfigs(kv, ls);

      final configs = await db.select(db.apiConfigs).get();
      expect(
        configs.isEmpty,
        isTrue,
        reason: 'Embedding-only preset should not create an API config row',
      );
    });
    test('imports multiple chat presets from connection presets', () async {
      final importer = JsApiConfigImporter(db, imageStorage);

      final presetsJson = jsonEncode([
        {
          'id': 'p1',
          'name': 'GPT-4',
          'endpoint': 'https://api.openai.com/v1',
          'apiKey': 'sk-gpt4',
          'model': 'gpt-4',
          'max_tokens': 4096,
          'context': 16000,
          'temp': 0.8,
          'topp': 0.95,
        },
        {
          'id': 'p2',
          'name': 'Claude',
          'endpoint': 'https://api.anthropic.com/v1',
          'apiKey': 'sk-claude',
          'model': 'claude-3-opus',
          'max_tokens': 8000,
          'context': 100000,
          'temp': 0.7,
          'topp': 0.9,
        },
        {
          'id': 'p3',
          'name': 'Local LLM',
          'endpoint': 'http://localhost:8080/v1',
          'apiKey': '',
          'model': 'llama-3-70b',
          'max_tokens': 2048,
          'context': 8192,
          'temp': 0.6,
          'topp': 0.85,
        },
      ]);

      final kv = <String, dynamic>{'gz_api_connection_presets': presetsJson};
      final ls = <String, dynamic>{};

      await importer.importApiConfigs(kv, ls);

      final configs = await db.select(db.apiConfigs).get();
      expect(
        configs.length,
        3,
        reason: 'All three chat presets should be imported',
      );
      final names = configs.map((c) => c.name).toSet();
      expect(names, containsAll(['GPT-4', 'Claude', 'Local LLM']));

      final gpt4 = configs.firstWhere((c) => c.configId == 'p1');
      expect(
        gpt4.endpoint,
        equals('https://api.openai.com/v1/chat/completions'),
      );
      expect(gpt4.maxTokens, equals(4096));
      expect(gpt4.contextSize, equals(16000));

      final claude = configs.firstWhere((c) => c.configId == 'p2');
      expect(
        claude.endpoint,
        equals('https://api.anthropic.com/v1/chat/completions'),
      );
      expect(claude.maxTokens, equals(8000));
      expect(claude.contextSize, equals(100000));

      final local = configs.firstWhere((c) => c.configId == 'p3');
      expect(
        local.endpoint,
        equals('http://localhost:8080/v1/chat/completions'),
      );
      expect(local.apiKey, isEmpty);
    });

    test(
      'imports multiple provider profiles including non-active chat profiles',
      () async {
        final importer = JsApiConfigImporter(db, imageStorage);

        final profilesJson = jsonEncode([
          {
            'id': 'llm1',
            'name': 'Main LLM',
            'endpoint': 'https://llm.example.com',
            'apiKey': 'sk-llm',
            'model': 'gpt-4o',
            'max_tokens': 8000,
            'context': 32000,
            'temp': 0.7,
            'topp': 0.9,
          },
          {
            'id': 'llm2',
            'name': 'Secondary LLM',
            'endpoint': 'https://backup.example.com',
            'apiKey': 'sk-backup',
            'model': 'claude-3.5',
            'max_tokens': 4096,
            'context': 200000,
            'temp': 0.5,
            'topp': 0.8,
          },
          {
            'id': 'emb1',
            'name': 'Embedding Service',
            'endpoint': 'https://emb.example.com',
            'apiKey': 'sk-emb',
            'model': 'text-embedding-3',
            'mode': 'embedding',
          },
        ]);

        final spmJson = jsonEncode({
          'llm': {'profileId': 'llm1'},
          'embedding': {'profileId': 'emb1', 'useSameAsLLM': false},
        });

        final kv = <String, dynamic>{};
        final ls = <String, dynamic>{
          'gz_provider_profiles': profilesJson,
          'gz_service_profile_map': spmJson,
        };

        await importer.importApiConfigs(kv, ls);

        final configs = await db.select(db.apiConfigs).get();
        expect(
          configs.length,
          2,
          reason:
              'LLM1 + LLM2 should be imported, embedding should be merged into LLM1',
        );

        final llm1 = configs.firstWhere((c) => c.configId == 'llm1');
        expect(llm1.name, equals('Main LLM'));
        expect(llm1.embeddingEnabled, isTrue);
        expect(llm1.embeddingUseSame, isFalse);
        expect(
          llm1.embeddingEndpoint,
          equals('https://emb.example.com/v1/embeddings'),
        );

        final llm2 = configs.firstWhere((c) => c.configId == 'llm2');
        expect(llm2.name, equals('Secondary LLM'));
        expect(
          llm2.endpoint,
          equals('https://backup.example.com/v1/chat/completions'),
        );
        expect(llm2.model, equals('claude-3.5'));
        expect(llm2.maxTokens, equals(4096));
        expect(llm2.contextSize, equals(200000));
      },
    );

    test('non-LLM provider profiles preserve per-preset settings', () async {
      final importer = JsApiConfigImporter(db, imageStorage);

      final profilesJson = jsonEncode([
        {
          'id': 'llm1',
          'name': 'Main',
          'endpoint': 'https://llm.example.com',
          'apiKey': 'sk-llm',
          'model': 'gpt-4o',
          'max_tokens': 8000,
          'context': 32000,
          'temp': 0.7,
          'topp': 0.9,
        },
        {
          'id': 'llm2',
          'name': 'Other',
          'endpoint': 'https://other.example.com',
          'apiKey': 'sk-other',
          'model': 'llama-3',
          'max_tokens': 2048,
          'context': 8192,
          'temp': 0.5,
          'topp': 0.7,
        },
      ]);

      final kv = <String, dynamic>{};
      final ls = <String, dynamic>{
        'gz_provider_profiles': profilesJson,
        'gz_active_llm_profile_id': 'llm1',
      };

      await importer.importApiConfigs(kv, ls);

      final configs = await db.select(db.apiConfigs).get();
      expect(configs.length, 2);

      final other = configs.firstWhere((c) => c.configId == 'llm2');
      expect(
        other.maxTokens,
        equals(2048),
        reason: 'Non-active profile should keep its own max_tokens',
      );
      expect(
        other.contextSize,
        equals(8192),
        reason: 'Non-active profile should keep its own context',
      );
      expect(
        other.temperature,
        closeTo(0.5, 0.01),
        reason: 'Non-active profile should keep its own temperature',
      );
    });
    test(
      'full provider profiles import: chat + embedding + image_gen + memory_books land in correct stores',
      () async {
        final importer = JsApiConfigImporter(db, imageStorage);

        final profilesJson = jsonEncode([
          {
            'id': 'llm1',
            'name': 'Main LLM',
            'endpoint': 'https://llm.example.com',
            'apiKey': 'sk-llm',
            'model': 'gpt-4o',
            'max_tokens': 8000,
            'context': 32000,
            'temp': 0.7,
            'topp': 0.9,
          },
          {
            'id': 'llm2',
            'name': 'Backup LLM',
            'endpoint': 'https://backup.example.com',
            'apiKey': 'sk-backup',
            'model': 'claude-3',
            'max_tokens': 4096,
            'context': 200000,
            'temp': 0.5,
            'topp': 0.8,
          },
          {
            'id': 'emb1',
            'name': 'Embedding',
            'endpoint': 'https://emb.example.com',
            'apiKey': 'sk-emb',
            'model': 'text-embedding-3',
            'mode': 'embedding',
          },
          {
            'id': 'imggen1',
            'name': 'Image Gen',
            'endpoint': 'https://imggen.example.com',
            'apiKey': 'sk-imggen',
            'model': 'dall-e-3',
            'mode': 'image_gen',
          },
          {
            'id': 'mb1',
            'name': 'Memory Books',
            'endpoint': 'https://mb.example.com',
            'apiKey': 'sk-mb',
            'model': 'gpt-4o-mini',
            'mode': 'memory_books',
          },
        ]);

        final spmJson = jsonEncode({
          'llm': {'profileId': 'llm1'},
          'embedding': {'profileId': 'emb1', 'useSameAsLLM': false},
          'image_gen': {'profileId': 'imggen1', 'useSameAsLLM': false},
          'memory_books': {'profileId': 'mb1', 'useSameAsLLM': false},
        });

        final kv = <String, dynamic>{};
        final ls = <String, dynamic>{
          'gz_provider_profiles': profilesJson,
          'gz_service_profile_map': spmJson,
        };

        await importer.importApiConfigs(kv, ls);

        final configs = await db.select(db.apiConfigs).get();
        expect(
          configs.length,
          2,
          reason:
              'Exactly 2 apiConfig rows: llm1 + llm2. '
              'Embedding merges into llm1, image_gen and memory_books go to SharedPreferences.',
        );

        final llm1 = configs.firstWhere((c) => c.configId == 'llm1');
        expect(llm1.name, equals('Main LLM'));
        expect(
          llm1.endpoint,
          equals('https://llm.example.com/v1/chat/completions'),
        );
        expect(llm1.embeddingEnabled, isTrue);
        expect(llm1.embeddingUseSame, isFalse);
        expect(
          llm1.embeddingEndpoint,
          equals('https://emb.example.com/v1/embeddings'),
        );
        expect(llm1.embeddingApiKey, equals('sk-emb'));
        expect(llm1.embeddingModel, equals('text-embedding-3'));

        final llm2 = configs.firstWhere((c) => c.configId == 'llm2');
        expect(llm2.name, equals('Backup LLM'));
        expect(llm2.model, equals('claude-3'));
        expect(
          llm2.embeddingEnabled,
          isFalse,
          reason:
              'Non-active LLM should not inherit embedding from active profile',
        );

        final configIds = configs.map((c) => c.configId).toList();
        expect(
          configIds,
          isNot(contains('emb1')),
          reason: 'Embedding profile must NOT become its own apiConfig row',
        );
        expect(
          configIds,
          isNot(contains('imggen1')),
          reason: 'Image gen profile must NOT become its own apiConfig row',
        );
        expect(
          configIds,
          isNot(contains('mb1')),
          reason: 'Memory books profile must NOT become its own apiConfig row',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('gz_imggen_endpoint'),
          equals('https://imggen.example.com'),
        );
        expect(prefs.getString('gz_imggen_api_key'), equals('sk-imggen'));
        expect(prefs.getString('gz_imggen_model'), equals('dall-e-3'));
        expect(prefs.getBool('gz_imggen_use_same'), isFalse);

        final memRaw = prefs.getString('memorySettings');
        expect(
          memRaw,
          isNotNull,
          reason: 'Memory books profile should write to memorySettings',
        );
        final memSettings = jsonDecode(memRaw!) as Map<String, dynamic>;
        expect(
          memSettings['generationSource'],
          equals('custom'),
          reason: 'useSameAsLLM=false should set generationSource=custom',
        );
        expect(
          memSettings['generationEndpoint'],
          equals('https://mb.example.com'),
        );
        expect(memSettings['generationApiKey'], equals('sk-mb'));
        expect(memSettings['generationModel'], equals('gpt-4o-mini'));
      },
    );

    test(
      'image_gen and memory_books with useSameAsLLM=true set flags without endpoint/key/model',
      () async {
        final importer = JsApiConfigImporter(db, imageStorage);

        final profilesJson = jsonEncode([
          {
            'id': 'llm1',
            'name': 'Main LLM',
            'endpoint': 'https://llm.example.com',
            'apiKey': 'sk-llm',
            'model': 'gpt-4o',
          },
          {
            'id': 'imggen1',
            'name': 'Image Gen Same',
            'endpoint': 'https://llm.example.com',
            'apiKey': 'sk-llm',
            'model': 'gpt-4o',
            'mode': 'image_gen',
          },
          {
            'id': 'mb1',
            'name': 'Memory Books Same',
            'endpoint': 'https://llm.example.com',
            'apiKey': 'sk-llm',
            'model': 'gpt-4o',
            'mode': 'memory_books',
          },
        ]);

        final spmJson = jsonEncode({
          'llm': {'profileId': 'llm1'},
          'image_gen': {'profileId': 'imggen1', 'useSameAsLLM': true},
          'memory_books': {'profileId': 'mb1', 'useSameAsLLM': true},
        });

        final kv = <String, dynamic>{};
        final ls = <String, dynamic>{
          'gz_provider_profiles': profilesJson,
          'gz_service_profile_map': spmJson,
        };

        await importer.importApiConfigs(kv, ls);

        final configs = await db.select(db.apiConfigs).get();
        expect(
          configs.length,
          1,
          reason: 'Only LLM chat profile, no separate imggen/mb rows',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('gz_imggen_use_same'), isTrue);
        expect(
          prefs.getString('gz_imggen_endpoint'),
          isNull,
          reason:
              'When useSameAsLLM=true, imggen endpoint/key/model prefs should not be set',
        );
        expect(prefs.getString('gz_imggen_api_key'), isNull);
        expect(prefs.getString('gz_imggen_model'), isNull);

        final memRaw = prefs.getString('memorySettings');
        expect(memRaw, isNotNull);
        final memSettings = jsonDecode(memRaw!) as Map<String, dynamic>;
        expect(
          memSettings['generationSource'],
          equals('current'),
          reason: 'useSameAsLLM=true should set generationSource=current',
        );
        expect(memSettings['generationUseCurrentModelOverride'], isTrue);
        expect(
          memSettings['generationEndpoint'],
          allOf(isNotNull, isEmpty),
          reason: 'When useSameAsLLM=true, endpoint should be empty',
        );
        expect(memSettings['generationApiKey'], allOf(isNotNull, isEmpty));
        expect(memSettings['generationModel'], allOf(isNotNull, isEmpty));
      },
    );

    test(
      'image_gen and memory_books profiles without service_profile_map write from profile mode',
      () async {
        final importer = JsApiConfigImporter(db, imageStorage);

        final profilesJson = jsonEncode([
          {
            'id': 'llm1',
            'name': 'Main LLM',
            'endpoint': 'https://llm.example.com',
            'apiKey': 'sk-llm',
            'model': 'gpt-4o',
          },
          {
            'id': 'imggen1',
            'name': 'Image Gen',
            'endpoint': 'https://imggen.example.com',
            'apiKey': 'sk-imggen',
            'model': 'dall-e-3',
            'mode': 'image_gen',
          },
          {
            'id': 'mb1',
            'name': 'Memory Books',
            'endpoint': 'https://mb.example.com',
            'apiKey': 'sk-mb',
            'model': 'gpt-4o-mini',
            'mode': 'memory_books',
          },
        ]);

        final kv = <String, dynamic>{};
        final ls = <String, dynamic>{'gz_provider_profiles': profilesJson};

        await importer.importApiConfigs(kv, ls);

        final configs = await db.select(db.apiConfigs).get();
        expect(
          configs.length,
          1,
          reason: 'Only LLM row, image_gen and memory_books go to prefs',
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('gz_imggen_endpoint'),
          equals('https://imggen.example.com'),
        );
        expect(prefs.getString('gz_imggen_api_key'), equals('sk-imggen'));
        expect(prefs.getString('gz_imggen_model'), equals('dall-e-3'));
        expect(
          prefs.getBool('gz_imggen_use_same'),
          isFalse,
          reason:
              'Without SPM, standalone image_gen profile implies useSameAsLLM=false',
        );

        final memRaw = prefs.getString('memorySettings');
        expect(
          memRaw,
          isNotNull,
          reason:
              'Without SPM, standalone memory_books profile should still write to memorySettings',
        );
        final memSettings = jsonDecode(memRaw!) as Map<String, dynamic>;
        expect(memSettings['generationSource'], equals('custom'));
        expect(
          memSettings['generationEndpoint'],
          equals('https://mb.example.com'),
        );
        expect(memSettings['generationApiKey'], equals('sk-mb'));
        expect(memSettings['generationModel'], equals('gpt-4o-mini'));
      },
    );
  });

  group('JsLorebookImporter', () {
    test('imports lorebooks from list format', () async {
      final importer = JsLorebookImporter(db, imageStorage);

      final kv = <String, dynamic>{
        'gz_lorebooks': [
          {
            'id': 'lb1',
            'name': 'World Lore',
            'enabled': true,
            'entries': [
              {
                'keys': ['castle', 'throne'],
                'content': 'The castle stands on a hill.',
                'enabled': true,
                'position': 0,
              },
            ],
          },
        ],
      };

      await importer.importLorebooks(kv);

      final rows = await db.select(db.lorebooks).get();
      expect(rows.length, 1);
      expect(rows.first.lorebookId, equals('lb1'));
      expect(rows.first.name, equals('World Lore'));
      expect(rows.first.activationScope, equals('global'));

      final entries = jsonDecode(rows.first.entriesJson) as List;
      expect(entries.length, 1);
      expect(entries.first['content'], equals('The castle stands on a hill.'));
    });

    test(
      'imports lorebooks from map format with settings and activations',
      () async {
        final importer = JsLorebookImporter(db, imageStorage);

        final kv = <String, dynamic>{
          'gz_lorebooks': {
            'lorebooks': [
              {
                'id': 'lb2',
                'name': 'Char Lore',
                'enabled': true,
                'activationScope': 'character',
                'activationTargetId': 'char1',
                'entries': [
                  {
                    'keys': ['magic'],
                    'content': 'Magic is real.',
                    'enabled': true,
                    'position': 1,
                  },
                ],
              },
            ],
            'settings': {'scanDepth': 5, 'matchWholeWords': 'false'},
            'activations': {
              'character': {'lb2': true},
            },
          },
        };

        await importer.importLorebooks(kv);

        final rows = await db.select(db.lorebooks).get();
        expect(rows.length, 1);
        expect(rows.first.lorebookId, equals('lb2'));
        expect(rows.first.activationScope, equals('character'));
        expect(rows.first.activationTargetId, equals('char1'));
        expect(rows.first.settingsJson, isNotNull);
        expect(rows.first.settingsJson, isNotEmpty);

        final prefs = await SharedPreferences.getInstance();
        final actStr = prefs.getString('lorebookActivations');
        expect(actStr, isNotNull);
        final activations = jsonDecode(actStr!) as Map<String, dynamic>;
        expect(activations['character'], isNotNull);
      },
    );

    test('imports character books from character data', () async {
      final importer = JsLorebookImporter(db, imageStorage);

      final charData = [
        {
          'id': 'char1',
          'name': 'Test Character',
          'character_book': {
            'name': 'Char1 Book',
            'entries': [
              {
                'keys': ['sword'],
                'content': 'A legendary sword.',
                'enabled': true,
                'position': 0,
              },
            ],
          },
        },
      ];

      await importer.importCharacterBooks(charData);

      final rows = await db.select(db.lorebooks).get();
      expect(rows.length, 1);
      expect(rows.first.lorebookId, equals('cb_char1'));
      expect(rows.first.activationScope, equals('character'));
      expect(rows.first.activationTargetId, equals('char1'));
    });

    test('does not duplicate character books on re-import', () async {
      final importer = JsLorebookImporter(db, imageStorage);

      final charData = [
        {
          'id': 'char1',
          'name': 'Test',
          'character_book': {
            'name': 'Book',
            'entries': [
              {
                'keys': ['test'],
                'content': 'Test entry.',
                'enabled': true,
                'position': 0,
              },
            ],
          },
        },
      ];

      await importer.importCharacterBooks(charData);
      await importer.importCharacterBooks(charData);

      final rows = await db.select(db.lorebooks).get();
      expect(
        rows.length,
        1,
        reason: 'Re-importing should not create duplicates',
      );
    });

    test('handles lorebook entries in map format', () async {
      final importer = JsLorebookImporter(db, imageStorage);

      final kv = <String, dynamic>{
        'gz_lorebooks': [
          {
            'id': 'lb_map',
            'name': 'Map Entries',
            'entries': {
              '0': {
                'keys': ['key1'],
                'content': 'Entry from map.',
                'enabled': true,
                'position': 0,
              },
              '1': {
                'keys': ['key2'],
                'content': 'Another entry.',
                'enabled': false,
                'position': 1,
              },
            },
          },
        ],
      };

      await importer.importLorebooks(kv);

      final rows = await db.select(db.lorebooks).get();
      expect(rows.length, 1);
      final entries = jsonDecode(rows.first.entriesJson) as List;
      expect(entries.length, 2);
    });

    test(
      'mapJsLorebookEntry handles selective logic and secondary keys',
      () async {
        final importer = JsLorebookImporter(db, imageStorage);

        final kv = <String, dynamic>{
          'gz_lorebooks': [
            {
              'id': 'lb_sel',
              'name': 'Selective',
              'entries': [
                {
                  'keys': ['primary'],
                  'keysecondary': ['secondary1', 'secondary2'],
                  'content': 'Selective entry.',
                  'enabled': true,
                  'selectiveLogic': 1,
                  'position': 0,
                  'constant': true,
                },
              ],
            },
          ],
        };

        await importer.importLorebooks(kv);

        final rows = await db.select(db.lorebooks).get();
        final entries = jsonDecode(rows.first.entriesJson) as List;
        final entry = entries.first as Map<String, dynamic>;
        expect(entry['secondaryKeys'], equals(['secondary1', 'secondary2']));
        expect(entry['selectiveLogic'], equals(1));
        expect(entry['constant'], isTrue);
      },
    );
  });

  group('ImportCancellationToken', () {
    test('check throws ImportCancelledException when cancelled', () {
      var cancelled = false;
      var checks = 0;
      final token = ImportCancellationToken.wrap(
        isCancelled: () => cancelled,
        check: () {
          checks++;
          if (cancelled) {
            throw const ImportCancelledException();
          }
        },
      );
      expect(token.isCancelled, isFalse);
      token.check();
      expect(checks, 1);
      cancelled = true;
      expect(token.isCancelled, isTrue);
      expect(() => token.check(), throwsA(isA<ImportCancelledException>()));
      expect(checks, 2);
    });
  });

  group('FlutterBackupImporter _restorePreferences', () {
    /// Builds a minimal valid v3 .glz ZIP archive in memory with an optional
    /// [preferences] map written as preferences.json.
    Archive buildGlzArchive({Map<String, dynamic>? preferences}) {
      final archive = Archive();

      // manifest.json
      final manifest = jsonEncode({
        '_isGlazeBackup': true,
        'schemaVersion': 3,
        '_glazeVersion': 3,
        'exportedAt': '2026-06-10T00:00:00.000Z',
        '_source': 'flutter',
      });
      archive.addFile(
        ArchiveFile.bytes('manifest.json', utf8.encode(manifest)),
      );

      // preferences.json (optional)
      if (preferences != null) {
        archive.addFile(
          ArchiveFile.bytes(
            'preferences.json',
            utf8.encode(jsonEncode(preferences)),
          ),
        );
      }

      return archive;
    }

    /// Writes [archive] to a temp file, runs the importer, returns the path.
    Future<String> writeAndImport(
      Archive archive,
      AppDatabase db,
      ImageStorageService imageStorage,
    ) async {
      final bytes = ZipEncoder().encode(archive);
      final path =
          '${Directory.systemTemp.path}/glz_prefs_test_${DateTime.now().microsecondsSinceEpoch}.glz';
      File(path).writeAsBytesSync(bytes);
      try {
        await FlutterBackupImporter(db, imageStorage).importFromZipFile(path);
      } finally {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      return path;
    }

    Future<void> importArchive(Archive archive) async {
      final bytes = ZipEncoder().encode(archive);
      final path =
          '${Directory.systemTemp.path}/glz_schema_test_${DateTime.now().microsecondsSinceEpoch}.glz';
      File(path).writeAsBytesSync(bytes);
      try {
        await FlutterBackupImporter(db, imageStorage).importFromZipFile(path);
      } finally {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
    }

    test('rejects backups from a newer schema version', () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(jsonEncode({'schemaVersion': 13})),
          ),
        );

      await expectLater(
        importArchive(archive),
        throwsA(isA<FormatException>()),
      );
    });

    test('v11 empty authoritative table clears existing rows', () async {
      await db.customStatement(
        "INSERT INTO rewrite_jobs (id, chat_session_id, character_id) VALUES ('stale', 's1', 'c1')",
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(jsonEncode({'schemaVersion': 11})),
          ),
        )
        ..addFile(ArchiveFile.bytes('tables/rewrite_jobs.jsonl', const []));

      await importArchive(archive);

      expect(await db.select(db.rewriteJobs).get(), isEmpty);
    });

    test('v11 clears Agent Ops state absent from legacy archives', () async {
      await db.customStatement(
        "INSERT INTO ledger_reconciliation_checkpoints (session_id, start_message_id, end_message_id) VALUES ('stale-session', 'm1', 'm2')",
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(jsonEncode({'schemaVersion': 11})),
          ),
        );

      await importArchive(archive);

      expect(
        await db.select(db.ledgerReconciliationCheckpoints).get(),
        isEmpty,
      );
    });

    test('accepts backup schema v12', () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(jsonEncode({'schemaVersion': 12})),
          ),
        )
        ..addFile(
          ArchiveFile.bytes(
            'tables/ledger_reconciliation_checkpoints.jsonl',
            const [],
          ),
        );

      await importArchive(archive);
    });

    test('restores all supported types from preferences.json', () async {
      final prefs = {
        'theme_presets': '[{"id":"p1"}]',
        'theme_active_preset': 'p1',
        'theme_accent': '7996CE',
        'activePresetId': 'preset-42',
        'activeStudioPresetId': 'studio_loom_causal_direct_v1',
        'enterToSend': true,
        'someInt': 42,
        'someDouble': 3.14,
        'stringList': ['a', 'b', 'c'],
      };

      await writeAndImport(
        buildGlzArchive(preferences: prefs),
        db,
        imageStorage,
      );

      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('theme_presets'), equals('[{"id":"p1"}]'));
      expect(sp.getString('theme_active_preset'), equals('p1'));
      expect(sp.getString('theme_accent'), equals('7996CE'));
      expect(sp.getString('activePresetId'), equals('preset-42'));
      expect(
        sp.getString('activeStudioPresetId'),
        equals('studio_loom_causal_direct_v1'),
      );
      expect(sp.getBool('enterToSend'), isTrue);
      expect(sp.getInt('someInt'), equals(42));
      expect(sp.getDouble('someDouble'), closeTo(3.14, 0.001));
      expect(sp.getStringList('stringList'), equals(['a', 'b', 'c']));
    });

    test('restores Studio preset blocks in canonical order', () async {
      final blocks = [
        {
          'id': 'anime',
          'title': 'Anime-Style Story',
          'kind': 'prompt',
          'role': 'system',
          'section': 'final',
          'enabled': true,
          'content': '<loomstyle>anime</loomstyle>',
        },
        {
          'id': 'bratty',
          'title': 'Bratty Ass Narrative',
          'kind': 'prompt',
          'role': 'system',
          'section': 'final',
          'enabled': false,
          'content': '<loomstyle>bratty</loomstyle>',
        },
      ];
      final archive = buildGlzArchive();
      archive.addFile(
        ArchiveFile.bytes(
          'tables/studio_preset_rows.jsonl',
          utf8.encode(
            '${jsonEncode({'preset_id': 'studio_loom_causal_direct_v1', 'name': 'Loom Direct', 'blocks_json': jsonEncode(blocks), 'agent_enabled_json': '{}', 'execution_mode': 'direct', 'updated_at': 42})}\n',
          ),
        ),
      );

      await writeAndImport(archive, db, imageStorage);

      final row = await db
          .customSelect(
            'SELECT blocks_json FROM studio_preset_rows WHERE preset_id = ?',
            variables: [
              drift.Variable.withString('studio_loom_causal_direct_v1'),
            ],
          )
          .getSingle();
      final restored = jsonDecode(row.read<String>('blocks_json')) as List;
      expect(restored.map((block) => block['id']), ['anime', 'bratty']);
      expect(restored.first['type'], 'instruction');
      expect(restored.first, isNot(contains('kind')));
      expect(restored.last['enabled'], isFalse);
    });

    test('stages legacy Studio config runtime into restored presets', () async {
      final archive = buildGlzArchive();
      final customBlocks = jsonEncode([
        {
          'id': 'custom',
          'type': 'instruction',
          'content': 'keep custom blocks',
          'section': 'final',
        },
      ]);
      archive.addFile(
        ArchiveFile.bytes(
          'tables/studio_preset_rows.jsonl',
          utf8.encode(
            '${jsonEncode({'preset_id': 'custom', 'name': 'Custom', 'blocks_json': customBlocks, 'agent_enabled_json': '{"final":true}', 'execution_mode': 'direct', 'updated_at': 42})}\n',
          ),
        ),
      );
      archive.addFile(
        ArchiveFile.bytes(
          'tables/studio_config_rows.jsonl',
          utf8.encode(
            '${jsonEncode({
              'session_id': 'session-1',
              'run_api_config_id': 'legacy-api',
              'expensive_api_config_id': 'explicit-api',
              'max_final_history_messages': 19,
              'updated_at': 10,
              'agents_json': jsonEncode([
                {'id': 'agent_session-1_continuity_123', 'sourceBlockNames': 'legacy'},
              ]),
            })}\n',
          ),
        ),
      );

      await writeAndImport(archive, db, imageStorage);

      final row = await db
          .customSelect(
            'SELECT blocks_json, agents_json, expensive_api_config_id, '
            'cheap_api_config_id, cleaner_api_config_id, '
            'max_final_history_messages, agent_enabled_json, execution_mode '
            'FROM studio_preset_rows WHERE preset_id = ?',
            variables: [drift.Variable.withString('custom')],
          )
          .getSingle();
      final restored = jsonDecode(row.read<String>('agents_json')) as List;
      expect(restored.single['controllerId'], 'continuity');
      expect(restored.single, isNot(contains('sourceBlockNames')));
      expect(row.read<String>('expensive_api_config_id'), 'explicit-api');
      expect(row.read<String>('cheap_api_config_id'), 'legacy-api');
      expect(row.read<String>('cleaner_api_config_id'), 'legacy-api');
      expect(row.read<int>('max_final_history_messages'), 19);
      final restoredBlocks =
          jsonDecode(row.read<String>('blocks_json')) as List;
      expect(restoredBlocks.single['id'], 'custom');
      expect(restoredBlocks.single['content'], 'keep custom blocks');
      expect(row.read<String>('agent_enabled_json'), '{"final":true}');
      expect(row.read<String>('execution_mode'), 'direct');
    });

    test(
      'legacy JSON table import stages Studio runtime after any map order',
      () async {
        final preset = {
          'preset_id': 'legacy-custom',
          'name': 'Legacy Custom',
          'blocks_json': '[]',
          'agent_enabled_json': '{}',
          'execution_mode': 'assisted',
          'updated_at': 5,
        };
        final config = {
          'session_id': 'profile',
          'profile_id': 'profile',
          'agents_json': jsonEncode([
            {'id': 'final', 'controllerId': 'final'},
          ]),
          'run_api_config_id': 'legacy-api',
          'max_final_history_messages': 11,
          'updated_at': 9,
        };

        await FlutterBackupImporter(db, imageStorage).importFromLegacyJson({
          'tables': {
            'studio_preset_rows': [preset],
            'studio_config_rows': [config],
          },
        });

        final row = await db
            .customSelect(
              "SELECT agents_json, expensive_api_config_id, max_final_history_messages "
              "FROM studio_preset_rows WHERE preset_id = 'legacy-custom'",
            )
            .getSingle();
        expect(jsonDecode(row.read<String>('agents_json')), hasLength(1));
        expect(row.read<String>('expensive_api_config_id'), 'legacy-api');
        expect(row.read<int>('max_final_history_messages'), 11);
      },
    );

    test('restores info blocks with the reserved order column', () async {
      final archive = buildGlzArchive();
      archive.addFile(
        ArchiveFile.bytes(
          'tables/info_blocks.jsonl',
          utf8.encode(
            '${jsonEncode({'id': 'block-1', 'session_id': 'session-1', 'message_id': 'message-1', 'swipe_id': 0, 'agent_swipe_id': -1, 'block_id': 'summary', 'block_name': 'Summary', 'block_type': 'info', 'content': 'Restored content', 'created_at': 42, 'order': 7, 'status': 'done'})}\n',
          ),
        ),
      );

      await writeAndImport(archive, db, imageStorage);

      final row = await db
          .customSelect(
            'SELECT "order", content FROM info_blocks WHERE id = ?',
            variables: [drift.Variable.withString('block-1')],
          )
          .getSingle();
      expect(row.read<int>('order'), 7);
      expect(row.read<String>('content'), 'Restored content');
    });

    test('silently skips missing preferences.json (v2 backups)', () async {
      // Archive has no preferences.json — should not throw.
      await expectLater(
        writeAndImport(buildGlzArchive(), db, imageStorage),
        completes,
      );
    });

    test('does not crash on malformed preferences.json', () async {
      final archive = buildGlzArchive();
      archive.addFile(
        ArchiveFile.bytes(
          'preferences.json',
          utf8.encode('this is not json {{{'),
        ),
      );

      await expectLater(writeAndImport(archive, db, imageStorage), completes);
    });

    test('overwrites existing prefs with values from backup', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('theme_active_preset', 'old-preset');

      await writeAndImport(
        buildGlzArchive(preferences: {'theme_active_preset': 'new-preset'}),
        db,
        imageStorage,
      );

      expect(
        (await SharedPreferences.getInstance()).getString(
          'theme_active_preset',
        ),
        equals('new-preset'),
      );
    });
  });

  group('StBackupImporter streaming import', () {
    test('importFromFile opens a SillyTavern ZIP via decodeStream and '
        'attempts to import chats from JSONL', () async {
      // Build a tiny ZIP that contains a single chat JSONL file. The
      // character-folder part of the path does not match a real
      // character in the DB, so the importer records an error in
      // result.errors instead of writing to the DB. The point of the
      // test is to exercise the decodeStream + LineSplitter path with
      // a real ZIP fixture and verify no exceptions bubble up.
      final archive = Archive();
      final chatJsonl = utf8.encode(
        '{"user_name":"Tester","character_name":"Test","chat_metadata":{}}\n'
        '{"name":"Tester","is_user":true,"is_system":false,"mes":"hi","send_date":"2024-01-01 12:00:00"}\n'
        '{"name":"Test","is_user":false,"is_system":false,"mes":"hello!","send_date":"2024-01-01 12:00:01"}\n',
      );
      archive.addFile(
        ArchiveFile.bytes('chats/UnknownChar/abc.jsonl', chatJsonl),
      );

      final fixturePath =
          '${Directory.systemTemp.path}/st_smoke_${DateTime.now().microsecondsSinceEpoch}.zip';
      final bytes = ZipEncoder().encode(archive);
      File(fixturePath).writeAsBytesSync(bytes);

      try {
        final importer = StBackupImporter(db, imageStorage);
        final result = await importer.importFromFile(fixturePath);
        // No chat row written, but no crash either. The expected
        // error is a 'no character matched folder' message.
        expect(result.chats, 0);
        expect(
          result.errors,
          isNotEmpty,
          reason:
              'expected an error for unmatched char folder, '
              'got ${result.errors}',
        );
        expect(
          result.errors.any((e) => e.contains('no character matched')),
          isTrue,
          reason: 'errors were: ${result.errors}',
        );
      } finally {
        try {
          File(fixturePath).deleteSync();
        } catch (_) {}
      }
    });
  });
}
