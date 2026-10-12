import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/archive_stream.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/services/backup/backup_secrets.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

void main() {
  group('BackupSecrets.isSecretField', () {
    test('matches credential names', () {
      for (final name in [
        'apiKey',
        'embeddingApiKey',
        'generationApiKey',
        'routmyApiKey',
        'api_key',
        'refresh_token',
        'accessToken',
        'token',
        'password',
        'client_secret',
      ]) {
        expect(BackupSecrets.isSecretField(name), isTrue, reason: name);
      }
    });

    test('leaves look-alikes alone', () {
      for (final name in [
        'key',
        'keys',
        'maxTokens',
        'tokenizer',
        'tokenCount',
        'pageToken',
        'scopeKey',
        'apiKeysIncluded',
      ]) {
        expect(BackupSecrets.isSecretField(name), isFalse, reason: name);
      }
    });
  });

  group('BackupSecrets prefs', () {
    test('drops credential prefs and blanks secrets inside JSON', () {
      final out = BackupSecrets.stripPrefs({
        'gz_sync_tokens': '{"dropbox":{"refresh_token":"r"}}',
        'gz_chub_api_key': 'chub',
        'pipelineSettings': jsonEncode({
          'memoryBookApi': {'generationApiKey': 'sk-1', 'model': 'm'},
          'maxTokens': 100,
        }),
        'plain': 'not json',
        'n': 3,
      });

      expect(out.containsKey('gz_sync_tokens'), isFalse);
      expect(out.containsKey('gz_chub_api_key'), isFalse);
      expect(jsonDecode(out['pipelineSettings'] as String), {
        'memoryBookApi': {'generationApiKey': '', 'model': 'm'},
        'maxTokens': 100,
      });
      expect(out['plain'], 'not json');
      expect(out['n'], 3);
    });

    test('untouched JSON keeps its original text', () {
      const raw = '{ "a" : 1 }';
      expect(BackupSecrets.stripPrefs({'x': raw})['x'], raw);
    });

    test('refill restores only the blanked secrets from the device', () {
      final backup = jsonEncode({
        'memoryBookApi': {'generationApiKey': '', 'model': 'new'},
        'imgApiKey': 'from-backup',
      });
      final local = jsonEncode({
        'memoryBookApi': {'generationApiKey': 'sk-local', 'model': 'old'},
        'imgApiKey': 'local',
      });

      final out = BackupSecrets.refillPref(backup, local);

      expect(jsonDecode(out as String), {
        'memoryBookApi': {'generationApiKey': 'sk-local', 'model': 'new'},
        'imgApiKey': 'from-backup',
      });
    });
  });

  group('keyless backup round trip', () {
    late AppDatabase db;
    late Directory tempDir;
    late ImageStorageService imageStorage;

    final pipeline = jsonEncode({
      'memoryBookApi': {'generationApiKey': 'sk-memory'},
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'gz_sync_tokens': '{"dropbox":{"refresh_token":"r"}}',
        'pipelineSettings': pipeline,
        'theme_accent': '7996CE',
      });
      db = AppDatabase.forTesting(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp('glaze_secrets_test_');
      imageStorage = ImageStorageService(tempDir.path);
      await db
          .into(db.apiConfigs)
          .insert(
            ApiConfigsCompanion.insert(
              configId: 'cfg1',
              name: 'Main',
              apiKey: const Value('sk-main'),
              embeddingApiKey: const Value('sk-embed'),
            ),
          );
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<Archive> export({required bool includeApiKeys}) async {
      final file = await BackupExporter(
        db,
        imageStorage,
        includeApiKeys: includeApiKeys,
      ).buildArchive(tempDir);
      return ZipDecoder().decodeStream(InputFileStream(file.path));
    }

    Future<Map<String, dynamic>> readJson(Archive a, String name) async =>
        jsonDecode(
              utf8.decode(
                a.files.firstWhere((f) => f.name == name).readBytes()!,
              ),
            )
            as Map<String, dynamic>;

    Future<Map<String, dynamic>> apiConfigRow(Archive a) async {
      final entry = a.files.firstWhere(
        (f) => f.name == 'tables/api_configs.jsonl',
      );
      final lines = await readArchiveFileLines(entry).toList();
      return jsonDecode(lines.single) as Map<String, dynamic>;
    }

    test('without keys the archive carries none', () async {
      final archive = await export(includeApiKeys: false);

      expect(
        (await readJson(archive, 'manifest.json'))[BackupSecrets.manifestFlag],
        isFalse,
      );
      final row = await apiConfigRow(archive);
      expect(row['api_key'], isNull);
      expect(row['embedding_api_key'], isNull);
      expect(row['name'], 'Main');

      final prefs = await readJson(archive, 'preferences.json');
      expect(prefs.containsKey('gz_sync_tokens'), isFalse);
      expect(prefs['theme_accent'], '7996CE');
      expect(prefs['pipelineSettings'], isNot(contains('sk-memory')));
    });

    test('with keys the archive is complete', () async {
      final archive = await export(includeApiKeys: true);

      expect(
        (await readJson(archive, 'manifest.json'))[BackupSecrets.manifestFlag],
        isTrue,
      );
      expect((await apiConfigRow(archive))['api_key'], 'sk-main');
      final prefs = await readJson(archive, 'preferences.json');
      expect(prefs['gz_sync_tokens'], isNotNull);
      expect(prefs['pipelineSettings'], pipeline);
    });

    test('restoring a keyless backup keeps the device keys', () async {
      final file = await BackupExporter(
        db,
        imageStorage,
        includeApiKeys: false,
      ).buildArchive(tempDir);

      await FlutterBackupImporter(
        db,
        imageStorage,
      ).importFromZipFile(file.path);

      final config = await db.select(db.apiConfigs).getSingle();
      expect(config.apiKey, 'sk-main');
      expect(config.embeddingApiKey, 'sk-embed');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gz_sync_tokens'), isNotNull);
      expect(prefs.getString('pipelineSettings'), contains('sk-memory'));
    });

    test(
      'restoring a keyless backup on a clean device leaves keys empty',
      () async {
        final file = await BackupExporter(
          db,
          imageStorage,
          includeApiKeys: false,
        ).buildArchive(tempDir);
        await db.delete(db.apiConfigs).go();
        SharedPreferences.setMockInitialValues({});

        await FlutterBackupImporter(
          db,
          imageStorage,
        ).importFromZipFile(file.path);

        final config = await db.select(db.apiConfigs).getSingle();
        expect(config.name, 'Main');
        expect(config.apiKey, anyOf(isNull, isEmpty));
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('gz_sync_tokens'), isNull);
      },
    );
  });
}
