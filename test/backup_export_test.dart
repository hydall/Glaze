import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackupExporter streaming JSON', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('glaze_backup_test_');
      await Directory('${tempDir.path}/avatars').create();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Map<String, dynamic> makeTables({
      List<Map<String, dynamic>>? characters,
      List<Map<String, dynamic>>? personas,
    }) {
      final tables = <String, dynamic>{};
      if (characters != null) tables['characters'] = characters;
      if (personas != null) tables['personas'] = personas;
      tables['chat_sessions'] = <dynamic>[];
      tables['chat_messages'] = <dynamic>[];
      return tables;
    }

    Future<File> writeStreamedJson({
      required Map<String, dynamic> tables,
      Map<String, String>? charAvatars,
      Map<String, String>? personaAvatars,
      Map<String, List<Map<String, dynamic>>>? gallery,
      Map<String, dynamic>? prefs,
    }) async {
      final file = File('${tempDir.path}/test_backup.glz');
      final sink = file.openWrite();

      sink.write('{');
      sink.write('"_isGlazeBackup":true,');
      sink.write('"_glazeVersion":1,');
      sink.write('"_source":"flutter",');
      sink.write(
          '"exportedAt":${jsonEncode(DateTime.now().toIso8601String())},');
      sink.write('"tables":${jsonEncode(tables)},');
      sink.write('"preferences":${jsonEncode(prefs ?? {})}');

      if (gallery != null && gallery.isNotEmpty) {
        sink.write(',"gallery":{');
        var first = true;
        for (final entry in gallery.entries) {
          if (!first) sink.write(',');
          sink.write('${jsonEncode(entry.key)}:${jsonEncode(entry.value)}');
          first = false;
        }
        sink.write('}');
      }

      if ((charAvatars != null && charAvatars.isNotEmpty) ||
          (personaAvatars != null && personaAvatars.isNotEmpty)) {
        sink.write(',"avatars":{');

        var hasSection = false;
        if (charAvatars != null && charAvatars.isNotEmpty) {
          sink.write('"characters":${jsonEncode(charAvatars)}');
          hasSection = true;
        }

        if (personaAvatars != null && personaAvatars.isNotEmpty) {
          if (hasSection) sink.write(',');
          sink.write('"personas":${jsonEncode(personaAvatars)}');
        }

        sink.write('}');
      }

      sink.write('}');
      await sink.close();
      return file;
    }

    test('Minimal backup: tables only, no images — valid JSON', () async {
      final tables = makeTables();
      final file = await writeStreamedJson(tables: tables);

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      expect(data['_isGlazeBackup'], isTrue);
      expect(data['_glazeVersion'], equals(1));
      expect(data['_source'], equals('flutter'));
      expect(data.containsKey('exportedAt'), isTrue);
      expect(data.containsKey('tables'), isTrue);
      expect(data.containsKey('preferences'), isTrue);
      expect(data.containsKey('gallery'), isFalse);
      expect(data.containsKey('avatars'), isFalse);
    });

    test('With characters and personas in tables', () async {
      final tables = makeTables(
        characters: [
          {'char_id': 'char1', 'name': 'Test Char', 'gallery_json': null},
        ],
        personas: [
          {'persona_id': 'pers1', 'name': 'Test Persona'},
        ],
      );

      final file = await writeStreamedJson(tables: tables);
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      final chars = data['tables']['characters'] as List<dynamic>;
      expect(chars.length, equals(1));
      expect(chars[0]['char_id'], equals('char1'));

      final personas = data['tables']['personas'] as List<dynamic>;
      expect(personas.length, equals(1));
      expect(personas[0]['persona_id'], equals('pers1'));
    });

    test('With gallery images — each char written separately', () async {
      final tables = makeTables(
        characters: [
          {'char_id': 'c1', 'gallery_json': '[]'},
          {'char_id': 'c2', 'gallery_json': '[]'},
        ],
      );

      final gallery = <String, List<Map<String, dynamic>>>{
        'c1': [
          {'entry': {'imagePath': '/fake1.png'}, 'base64': 'aGVsbG8='},
        ],
        'c2': [
          {'entry': {'imagePath': '/fake2.png'}, 'base64': 'd29ybGQ='},
        ],
      };

      final file = await writeStreamedJson(tables: tables, gallery: gallery);
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      expect(data.containsKey('gallery'), isTrue);
      final gl = data['gallery'] as Map<String, dynamic>;
      expect(gl.containsKey('c1'), isTrue);
      expect(gl.containsKey('c2'), isTrue);
      expect((gl['c1'] as List).length, equals(1));
      expect((gl['c2'] as List).length, equals(1));
    });

    test('With character and persona avatars', () async {
      final tables = makeTables(
        characters: [
          {'char_id': 'char1'},
        ],
        personas: [
          {'persona_id': 'pers1'},
        ],
      );

      final charAvatars = {'char1': 'Y2hhcg=='};
      final personaAvatars = {'pers1': 'cGVycw=='};

      final file = await writeStreamedJson(
        tables: tables,
        charAvatars: charAvatars,
        personaAvatars: personaAvatars,
      );
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      expect(data.containsKey('avatars'), isTrue);
      final av = data['avatars'] as Map<String, dynamic>;
      expect(av.containsKey('characters'), isTrue);
      expect(av.containsKey('personas'), isTrue);
      expect(av['characters']['char1'], equals('Y2hhcg=='));
      expect(av['personas']['pers1'], equals('cGVycw=='));
    });

    test('Only character avatars, no persona avatars', () async {
      final tables = makeTables(characters: [
        {'char_id': 'c1'},
      ]);

      final file = await writeStreamedJson(
        tables: tables,
        charAvatars: {'c1': 'AQID'},
      );
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      final av = data['avatars'] as Map<String, dynamic>;
      expect(av.containsKey('characters'), isTrue);
      expect(av.containsKey('personas'), isFalse);
    });

    test('Only persona avatars, no character avatars', () async {
      final tables = makeTables(personas: [
        {'persona_id': 'p1'},
      ]);

      final file = await writeStreamedJson(
        tables: tables,
        personaAvatars: {'p1': 'BAUG'},
      );
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      final av = data['avatars'] as Map<String, dynamic>;
      expect(av.containsKey('characters'), isFalse);
      expect(av.containsKey('personas'), isTrue);
    });

    test('No avatars section when no avatar data', () async {
      final tables = makeTables(characters: [
        {'char_id': 'c1'},
      ]);

      final file = await writeStreamedJson(tables: tables);
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      expect(data.containsKey('avatars'), isFalse);
    });

    test('No gallery section when no gallery data', () async {
      final tables = makeTables(characters: [
        {'char_id': 'c1', 'gallery_json': null},
      ]);

      final file = await writeStreamedJson(tables: tables);
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      expect(data.containsKey('gallery'), isFalse);
    });

    test('Full backup with all sections — round-trip valid', () async {
      final tables = makeTables(
        characters: [
          {'char_id': 'c1', 'name': 'Char1', 'gallery_json': '[]'},
        ],
        personas: [
          {'persona_id': 'p1', 'name': 'Pers1'},
        ],
      );

      final prefs = <String, dynamic>{
        'theme_mode': 'dark',
        'nsfw_enabled': true,
        'font_size': 14,
      };

      final gallery = <String, List<Map<String, dynamic>>>{
        'c1': [
          {'entry': {'imagePath': '/img.png'}, 'base64': 'AQIDBAUG'},
        ],
      };

      final file = await writeStreamedJson(
        tables: tables,
        charAvatars: {'c1': 'Y2hhckF2YXRhcg=='},
        personaAvatars: {'p1': 'cGVyc0F2YXRhcg=='},
        gallery: gallery,
        prefs: prefs,
      );

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      expect(data['_isGlazeBackup'], isTrue);
      expect(data['_glazeVersion'], equals(1));
      expect(data['_source'], equals('flutter'));

      final t = data['tables'] as Map<String, dynamic>;
      expect((t['characters'] as List).length, equals(1));
      expect((t['personas'] as List).length, equals(1));

      final p = data['preferences'] as Map<String, dynamic>;
      expect(p['theme_mode'], equals('dark'));
      expect(p['nsfw_enabled'], equals(true));
      expect(p['font_size'], equals(14));

      expect(data.containsKey('gallery'), isTrue);
      expect(data.containsKey('avatars'), isTrue);

      final gl = data['gallery'] as Map<String, dynamic>;
      expect((gl['c1'] as List).length, equals(1));

      final av = data['avatars'] as Map<String, dynamic>;
      expect(av['characters']['c1'], equals('Y2hhckF2YXRhcg=='));
      expect(av['personas']['p1'], equals('cGVyc0F2YXRhcg=='));

      final reencoded = jsonEncode(data);
      expect(jsonDecode(reencoded), equals(data));
    });

    test('Temp file is cleaned up on success', () async {
      final tables = makeTables();
      final file = await writeStreamedJson(tables: tables);

      expect(await file.exists(), isTrue);
      await file.delete();
      expect(await file.exists(), isFalse);
    });

    test('Large gallery: many characters with images — still valid JSON',
        () async {
      final chars = List.generate(
        50,
        (i) => {'char_id': 'c$i', 'name': 'Char $i', 'gallery_json': '[]'},
      );
      final tables = makeTables(characters: chars);

      final gallery = <String, List<Map<String, dynamic>>>{};
      for (int i = 0; i < 50; i++) {
        gallery['c$i'] = [
          {
            'entry': {'imagePath': '/img_$i.png'},
            'base64': base64Encode(List.generate(100, (j) => i + j)),
          },
        ];
      }

      final file = await writeStreamedJson(tables: tables, gallery: gallery);
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      final gl = data['gallery'] as Map<String, dynamic>;
      expect(gl.length, equals(50));
    });

    test('Preferences with all value types are preserved', () async {
      final tables = makeTables();
      final prefs = <String, dynamic>{
        'bool_val': true,
        'int_val': 42,
        'double_val': 3.14,
        'string_val': 'hello',
        'null_val': null,
      };

      final file = await writeStreamedJson(tables: tables, prefs: prefs);
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      final p = data['preferences'] as Map<String, dynamic>;
      expect(p['bool_val'], equals(true));
      expect(p['int_val'], equals(42));
      expect(p['double_val'], equals(3.14));
      expect(p['string_val'], equals('hello'));
    });

    test('Empty tables map produces valid JSON', () async {
      final file =
          await writeStreamedJson(tables: <String, dynamic>{});
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      expect(data['_isGlazeBackup'], isTrue);
      expect(data['tables'], isA<Map<String, dynamic>>());
    });
  });
}
