import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/character_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

class _TestImageStorage extends ImageStorageService {
  _TestImageStorage()
    : super(Directory.systemTemp.createTempSync('glaze_charx_test_').path);

  Uint8List? avatarBytes;

  @override
  Future<String> saveAvatar(String characterId, Uint8List imageBytes) async {
    avatarBytes = imageBytes;
    return '/fake/avatars/$characterId.png';
  }
}

void main() {
  late _TestImageStorage imageStorage;
  late CharacterImporter importer;

  setUp(() {
    imageStorage = _TestImageStorage();
    importer = CharacterImporter(imageStorage);
  });

  test('imports a regular CharX ZIP', () async {
    final result = await importer.importFromBytes(_charXBytes(), 'card.charx');

    expect(result.character.name, 'Risu character');
    expect(result.hadAvatar, isTrue);
    expect(imageStorage.avatarBytes, _iconBytes);
  });

  test('imports a Risu JPEG-prefixed CharX', () async {
    final zip = _charXBytes();
    final polyglot = Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xe0,
      0x00,
      0x10,
      0x4a,
      0x46,
      0x49,
      0x46,
      0x00,
      0xff,
      0xd9,
      ...zip,
    ]);

    final result = await importer.importFromBytes(polyglot, 'card.charx');

    expect(result.character.name, 'Risu character');
    expect(result.hadAvatar, isTrue);
    expect(imageStorage.avatarBytes, _iconBytes);
  });

  test('does not scan arbitrary prefixes for an embedded ZIP', () async {
    final prefixed = Uint8List.fromList([0x00, 0x01, 0x02, ..._charXBytes()]);

    expect(
      () => importer.importFromBytes(prefixed, 'card.charx'),
      throwsA(isA<FormatException>()),
    );
  });
}

final _iconBytes = Uint8List.fromList([1, 2, 3, 4]);

Uint8List _charXBytes() {
  final card = utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Risu character',
        'description': 'Test character',
        'assets': [
          {
            'type': 'icon',
            'name': 'main',
            'uri': 'embeded://assets/icon.png',
            'ext': 'png',
          },
        ],
      },
    }),
  );
  final archive = Archive()
    ..addFile(ArchiveFile('card.json', card.length, card))
    ..addFile(ArchiveFile('assets/icon.png', _iconBytes.length, _iconBytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
