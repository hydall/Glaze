import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/archive_stream.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late ImageStorageService imageStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('glaze_exporter_test_');
    imageStorage = ImageStorageService(tempDir.path);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'buildArchive streams a large table without buffering it in memory',
    () async {
      await db
          .into(db.characters)
          .insert(CharactersCompanion.insert(charId: 'c1', name: 'Char 1'));

      // ~6 MB of chat JSON so the table crosses the in-memory compression
      // threshold and must be added as a stored streaming entry.
      final hugeMessages = jsonEncode(
        List.generate(30000, (i) => {'role': 'user', 'content': 'x' * 200}),
      );
      await db
          .into(db.chatSessions)
          .insert(
            ChatSessionsCompanion.insert(
              sessionId: 's1',
              characterId: 'c1',
              sessionIndex: 0,
              messagesJson: hugeMessages,
            ),
          );
      await db
          .into(db.chatSessions)
          .insert(
            ChatSessionsCompanion.insert(
              sessionId: 's2',
              characterId: 'c1',
              sessionIndex: 1,
              messagesJson: '[]',
            ),
          );

      final archive = await BackupExporter(
        db,
        imageStorage,
      ).buildArchive(tempDir);
      expect(await archive.exists(), isTrue);
      addTearDown(() async {
        if (await archive.exists()) await archive.delete();
      });

      final decoded = ZipDecoder().decodeStream(InputFileStream(archive.path));
      final manifest = decoded.files
          .firstWhere((f) => f.name == 'manifest.json')
          .readBytes()!;
      expect(
        jsonDecode(utf8.decode(manifest))['schemaVersion'],
        BackupExporter.schemaVersion,
      );

      final chatEntry = decoded.files.firstWhere(
        (f) => f.name == 'tables/chat_sessions.jsonl',
      );
      expect(
        chatEntry.compression,
        CompressionType.none,
        reason: 'large table should be stored, not buffered/compressed',
      );

      final lines = await readArchiveFileLines(chatEntry).toList();
      expect(lines.length, 2);
      final rows = lines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final s1 = rows.firstWhere((r) => r['session_id'] == 's1');
      expect(s1['messages_json'], hugeMessages);
      final s2 = rows.firstWhere((r) => r['session_id'] == 's2');
      expect(s2['messages_json'], '[]');
    },
  );
}
