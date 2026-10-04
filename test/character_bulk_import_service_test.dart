import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/character_bulk_import_service.dart';
import 'package:glaze_flutter/core/services/character_import_write_buffer.dart';
import 'package:glaze_flutter/core/services/character_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

class _TestImageStorage extends ImageStorageService {
  _TestImageStorage()
    : super(Directory.systemTemp.createTempSync('glaze_bulk_import_').path);

  @override
  Future<String> saveAvatar(String characterId, Uint8List imageBytes) async =>
      '/fake/avatars/$characterId.png';
}

/// Records every write the buffer performs, so a test can assert both *what*
/// landed and *how many transactions* it took.
class _RecordingWrites {
  final List<List<String>> characterBatches = [];
  final List<List<String>> lorebookBatches = [];
  final List<String> galleryWrites = [];

  List<String> get characters => [
    for (final batch in characterBatches) ...batch,
  ];

  CharacterImportWriteBuffer buffer({int chunkSize = 2}) {
    return CharacterImportWriteBuffer(
      chunkSize: chunkSize,
      writeCharacters: (batch) async {
        characterBatches.add([for (final c in batch) c.name]);
      },
      writeLorebooks: (batch) async {
        lorebookBatches.add([for (final l in batch) l.name]);
      },
      writeGalleryImage: (characterId, image) async {
        galleryWrites.add('$characterId:${image.label}');
      },
    );
  }
}

Uint8List _cardBytes(String name) => Uint8List.fromList(
  utf8.encode(jsonEncode({'name': name, 'description': 'desc'})),
);

CharacterImportSource _source(String name, {Uint8List? bytes}) =>
    CharacterImportSource(
      name: '$name.json',
      openBytes: () async => bytes ?? _cardBytes(name),
    );

void main() {
  late _TestImageStorage imageStorage;
  late CharacterImporter importer;
  late _RecordingWrites writes;

  setUp(() {
    imageStorage = _TestImageStorage();
    importer = CharacterImporter(imageStorage);
    writes = _RecordingWrites();
  });

  CharacterBulkImportService serviceWith(
    CharacterImportWriteBuffer buffer, {
    Future<void> Function()? yieldToEventLoop,
  }) => CharacterBulkImportService(
    importer: importer,
    buffer: buffer,
    yieldToEventLoop: yieldToEventLoop,
  );

  test('imports every source and writes them in chunks', () async {
    final service = serviceWith(writes.buffer(chunkSize: 2));

    final report = await service.run([
      _source('a'),
      _source('b'),
      _source('c'),
      _source('d'),
      _source('e'),
    ]);

    expect(report.imported, 5);
    expect(report.failed, 0);
    expect(report.lastError, isNull);
    expect(writes.characters, ['a', 'b', 'c', 'd', 'e']);
    // 2 + 2 + the final flush — not one write per card.
    expect(writes.characterBatches.map((b) => b.length), [2, 2, 1]);
  });

  test('reads exactly one source at a time', () async {
    var open = 0;
    var maxOpen = 0;
    CharacterImportSource tracked(String name) => CharacterImportSource(
      name: '$name.json',
      openBytes: () async {
        open++;
        maxOpen = open > maxOpen ? open : maxOpen;
        await Future<void>.delayed(Duration.zero);
        open--;
        return _cardBytes(name);
      },
    );

    final service = serviceWith(writes.buffer(chunkSize: 2));
    await service.run([tracked('a'), tracked('b'), tracked('c')]);

    expect(maxOpen, 1);
  });

  test('a broken card fails alone and the run continues', () async {
    final service = serviceWith(writes.buffer(chunkSize: 10));

    final report = await service.run([
      _source('a'),
      _source('broken', bytes: Uint8List.fromList(utf8.encode('not json'))),
      _source('c'),
    ]);

    expect(report.imported, 2);
    expect(report.failed, 1);
    expect(report.lastError, contains('broken.json'));
    expect(writes.characters, ['a', 'c']);
  });

  test('a source that cannot be read is reported, not thrown', () async {
    final service = serviceWith(writes.buffer(chunkSize: 10));

    final report = await service.run([
      CharacterImportSource(name: 'gone.png', openBytes: () async => null),
    ]);

    expect(report.imported, 0);
    expect(report.failed, 1);
    expect(report.lastError, contains('gone.png'));
  });

  test(
    'cancelling stops the run and keeps what was already imported',
    () async {
      var processed = 0;
      final service = serviceWith(
        writes.buffer(chunkSize: 10),
        yieldToEventLoop: () async => processed++,
      );

      final report = await service.run([
        _source('a'),
        _source('b'),
        _source('c'),
        _source('d'),
      ], isCancelled: () => processed >= 2);

      expect(report.cancelled, isTrue);
      expect(report.imported, 2);
      expect(writes.characters, ['a', 'b']);
    },
  );

  test('reports progress per card and once at the end', () async {
    final service = serviceWith(writes.buffer(chunkSize: 10));
    final seen = <String>[];

    final report = await service.run(
      [_source('a'), _source('b')],
      onProgress: (p) => seen.add('${p.completed}/${p.total}:${p.currentName}'),
    );

    expect(seen, ['0/2:a.json', '1/2:b.json', '2/2:']);
    expect(report.imported, 2);
  });

  test('counts a failed final flush as failures, not imports', () async {
    final buffer = CharacterImportWriteBuffer(
      chunkSize: 10,
      writeCharacters: (_) async => throw StateError('db is gone'),
      writeLorebooks: (_) async {},
      writeGalleryImage: (_, _) async {},
    );
    final service = serviceWith(buffer);

    final report = await service.run([_source('a'), _source('b')]);

    expect(report.imported, 0);
    expect(report.failed, 2);
    expect(report.lastError, contains('db is gone'));
  });

  group('CharacterImportWriteBuffer', () {
    test(
      'flushes pending characters before attaching a gallery image',
      () async {
        final buffer = writes.buffer(chunkSize: 10);

        await buffer.addCharacter(const Character(id: 'char-1', name: 'a'));
        await buffer.addGalleryImage(
          'char-1',
          GalleryImageData(label: 'pic', bytes: Uint8List(0), ext: 'png'),
        );

        expect(writes.characters, ['a']);
        expect(writes.galleryWrites, ['char-1:pic']);
      },
    );

    test('keeps rows pending when a write fails', () async {
      var attempts = 0;
      final buffer = CharacterImportWriteBuffer(
        chunkSize: 10,
        writeCharacters: (batch) async {
          attempts++;
          if (attempts == 1) throw StateError('locked');
        },
        writeLorebooks: (_) async {},
        writeGalleryImage: (_, _) async {},
      );

      await buffer.addCharacter(const Character(id: 'char-1', name: 'a'));
      await expectLater(buffer.flush(), throwsStateError);
      expect(buffer.pendingCharacterCount, 1);

      await buffer.flush();
      expect(buffer.pendingCharacterCount, 0);
    });

    test('writes buffered lorebooks after their characters', () async {
      final buffer = writes.buffer(chunkSize: 10);

      await buffer.addCharacter(const Character(id: 'char-1', name: 'a'));
      await buffer.addLorebook(const Lorebook(id: 'book-1', name: 'book'));
      await buffer.flush();

      expect(writes.characterBatches, [
        ['a'],
      ]);
      expect(writes.lorebookBatches, [
        ['book'],
      ]);
    });
  });
}
