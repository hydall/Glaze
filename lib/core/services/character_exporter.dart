import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../models/character.dart';
import '../models/gallery_entry.dart';

class PngExportResult {
  final String filePath;
  PngExportResult({required this.filePath});
}

Future<PngExportResult> exportCharacterAsPng({
  required Character character,
  required Uint8List avatarBytes,
  required String outputDir,
  bool includeCharacterBook = false,
  Map<String, dynamic>? characterBookData,
}) async {
  final cardData = _buildV2Data(character, characterBookData: includeCharacterBook ? characterBookData : null);
  final jsonStr = jsonEncode(cardData);
  final base64Text = base64Encode(utf8.encode(jsonStr));

  final keyword = 'chara';
  final keywordBytes = Uint8List.fromList(utf8.encode(keyword));
  final textBytes = Uint8List.fromList(utf8.encode(base64Text));

  final chunkData = Uint8List(keywordBytes.length + 1 + textBytes.length);
  chunkData.setRange(0, keywordBytes.length, keywordBytes);
  chunkData[keywordBytes.length] = 0;
  chunkData.setRange(keywordBytes.length + 1, chunkData.length, textBytes);

  final chunkTypeBytes = Uint8List.fromList(utf8.encode('tEXt'));
  final crcInput = Uint8List(4 + chunkData.length);
  crcInput.setRange(0, 4, chunkTypeBytes);
  crcInput.setRange(4, crcInput.length, chunkData);
  final crcValue = _crc32(crcInput);

  final chunkFull = ByteData(4 + 4 + chunkData.length + 4);
  chunkFull.setUint32(0, chunkData.length, Endian.big);
  chunkFull.setUint8List(4, chunkTypeBytes);
  chunkFull.setUint8List(8, chunkData);
  chunkFull.setUint32(8 + chunkData.length, crcValue, Endian.big);

  final pngAvatar = _ensurePng(avatarBytes);
  final insertPos = _findIhdrEnd(pngAvatar);
  final resultPng = Uint8List(pngAvatar.length + chunkFull.lengthInBytes);
  resultPng.setRange(0, insertPos, pngAvatar);
  resultPng.setRange(insertPos, insertPos + chunkFull.lengthInBytes, chunkFull.buffer.asUint8List());
  resultPng.setRange(insertPos + chunkFull.lengthInBytes, resultPng.length, pngAvatar.sublist(insertPos));

  final safeName = (character.name.isEmpty ? 'character' : character.name)
      .replaceAll(RegExp(r'[/\\?%*:|"<>\.]'), '-')
      .trim();
  final filePath = p.join(outputDir, '$safeName.png');
  await File(filePath).writeAsBytes(resultPng);

  return PngExportResult(filePath: filePath);
}

Future<PngExportResult> exportCharacterAsJson({
  required Character character,
  required String outputDir,
  bool includeCharacterBook = false,
  Map<String, dynamic>? characterBookData,
}) async {
  final cardData = _buildV2Data(character, characterBookData: includeCharacterBook ? characterBookData : null);
  final jsonStr = const JsonEncoder.withIndent('  ').convert(cardData);

  final safeName = (character.name.isEmpty ? 'character' : character.name)
      .replaceAll(RegExp(r'[/\\?%*:|"<>\.]'), '-')
      .trim();
  final filePath = p.join(outputDir, '$safeName.json');
  await File(filePath).writeAsString(jsonStr);

  return PngExportResult(filePath: filePath);
}

Future<PngExportResult> exportCharacterAsZip({
  required Character character,
  required Uint8List avatarBytes,
  required String outputDir,
  Map<String, dynamic>? characterBookData,
  List<GalleryEntry> gallery = const [],
  List<Uint8List> galleryBytes = const [],
}) async {
  final assets = <Map<String, dynamic>>[];

  assets.add({
    'type': 'icon',
    'name': 'avatar',
    'uri': 'embedded://avatar.png',
    'ext': 'png',
  });

  final galleryMeta = <Map<String, dynamic>>[];
  for (int i = 0; i < gallery.length && i < galleryBytes.length; i++) {
    final entry = gallery[i];
    final ext = p.extension(entry.imagePath).replaceFirst('.', '');
    final safeExt = ext.isEmpty ? 'png' : ext;
    final fileName = 'gallery_$i.$safeExt';
    assets.add({
      'type': 'gallery',
      'name': entry.label ?? 'gallery_$i',
      'uri': 'embedded://gallery/$fileName',
      'ext': safeExt,
    });
    galleryMeta.add({
      'id': entry.id,
      'label': entry.label,
      'uri': 'embedded://gallery/$fileName',
    });
  }

  final cardData = _buildV2Data(
    character,
    characterBookData: characterBookData,
    assets: assets,
    galleryMeta: galleryMeta,
  );

  final archive = Archive();
  archive.addFile(ArchiveFile.string('card.json', jsonEncode(cardData)));
  archive.addFile(ArchiveFile.bytes('avatar.png', avatarBytes));

  for (int i = 0; i < gallery.length && i < galleryBytes.length; i++) {
    final entry = gallery[i];
    final ext = p.extension(entry.imagePath).replaceFirst('.', '');
    final safeExt = ext.isEmpty ? 'png' : ext;
    archive.addFile(ArchiveFile.bytes('gallery/gallery_$i.$safeExt', galleryBytes[i]));
  }

  final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));

  final safeName = (character.name.isEmpty ? 'character' : character.name)
      .replaceAll(RegExp(r'[/\\?%*:|"<>\.]'), '-')
      .trim();
  final filePath = p.join(outputDir, '$safeName.zip');
  await File(filePath).writeAsBytes(zipBytes);

  return PngExportResult(filePath: filePath);
}

Map<String, dynamic> _buildV2Data(Character character, {Map<String, dynamic>? characterBookData, List<Map<String, dynamic>>? assets, List<Map<String, dynamic>>? galleryMeta}) {
  final data = <String, dynamic>{
    'name': character.name,
    'description': character.description ?? '',
    'personality': character.personality ?? '',
    'scenario': character.scenario ?? '',
    'first_mes': character.firstMes ?? '',
    'mes_example': character.mesExample ?? '',
    'system_prompt': character.systemPrompt ?? '',
    'post_history_instructions': character.postHistoryInstructions ?? '',
    'creator': character.creator ?? '',
    'creator_notes': character.creatorNotes ?? '',
    'tags': character.tags,
    'alternate_greetings': character.alternateGreetings,
  };

  if (character.macroName != null && character.macroName!.isNotEmpty) {
    data['macro_name'] = character.macroName;
  }

  if (characterBookData != null) {
    data['character_book'] = characterBookData;
  }

  if (character.fav) {
    data['fav'] = true;
  }

  if (character.extensions.isNotEmpty) {
    final extCopy = Map<String, dynamic>.from(character.extensions);
    if (character.depthPrompt.isNotEmpty || character.depthPromptDepth != 4 || character.depthPromptRole != 'system') {
      extCopy['depth_prompt'] = {
        'prompt': character.depthPrompt,
        'depth': character.depthPromptDepth,
        'role': character.depthPromptRole,
      };
    }
    if (character.world != null) {
      extCopy['world'] = character.world;
    }
    data['extensions'] = extCopy;
  } else {
    if (character.depthPrompt.isNotEmpty || character.depthPromptDepth != 4 || character.depthPromptRole != 'system') {
      data['extensions'] = {
        'depth_prompt': {
          'prompt': character.depthPrompt,
          'depth': character.depthPromptDepth,
          'role': character.depthPromptRole,
        },
      };
    }
  }

  data['character_version'] = character.characterVersion;

  if (assets != null && assets.isNotEmpty) {
    data['assets'] = assets;
  }

  if (galleryMeta != null && galleryMeta.isNotEmpty) {
    final ext = data['extensions'] as Map<String, dynamic>? ?? {};
    ext['gallery'] = galleryMeta;
    data['extensions'] = ext;
  }

  return {
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': data,
  };
}

// IHDR data length is always 13 in valid PNG; guard against non-PNG bytes
// (e.g. JPEG from iOS photo library) which would produce a garbage insertPos.
int _findIhdrEnd(Uint8List pngBytes) {
  if (pngBytes.length < 33) return 8;
  final data = ByteData.sublistView(pngBytes);
  final ihdrLen = data.getUint32(8, Endian.big);
  if (ihdrLen != 13) return 33;
  return 8 + 4 + 4 + ihdrLen + 4;
}

bool _isPng(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 &&
    bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A;

Uint8List _ensurePng(Uint8List bytes) {
  if (_isPng(bytes)) return bytes;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw Exception('Could not decode avatar image for PNG export');
  return Uint8List.fromList(img.encodePng(decoded));
}

int _crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (int i = 0; i < data.length; i++) {
    crc ^= data[i];
    for (int j = 0; j < 8; j++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List generatePlaceholderAvatar(String name) {
  final width = 400, height = 600;

  final pngHeader = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  final ihdrData = ByteData(13);
  ihdrData.setUint32(0, width, Endian.big);
  ihdrData.setUint32(4, height, Endian.big);
  ihdrData.setUint8(8, 8);
  ihdrData.setUint8(9, 2);
  ihdrData.setUint8(10, 0);
  ihdrData.setUint8(11, 0);
  ihdrData.setUint8(12, 0);

  final ihdrChunk = _buildPngChunk('IHDR', ihdrData.buffer.asUint8List());

  final rawRow = Uint8List(1 + width * 3);
  for (int x = 0; x < width; x++) {
    rawRow[1 + x * 3] = 0x40;
    rawRow[1 + x * 3 + 1] = 0xCC;
    rawRow[1 + x * 3 + 2] = 0xFF;
  }

  final rawData = Uint8List(height * rawRow.length);
  for (int y = 0; y < height; y++) {
    rawData.setRange(y * rawRow.length, (y + 1) * rawRow.length, rawRow);
  }

  final iendChunk = _buildPngChunk('IEND', Uint8List(0));

  final result = BytesBuilder();
  result.add(pngHeader);
  result.add(ihdrChunk);
  result.add(iendChunk);
  return result.toBytes();
}

Uint8List _buildPngChunk(String type, Uint8List data) {
  final typeBytes = Uint8List.fromList(utf8.encode(type));
  final chunk = ByteData(4 + 4 + data.length + 4);
  chunk.setUint32(0, data.length, Endian.big);
  for (int i = 0; i < 4; i++) {
    chunk.setUint8(4 + i, typeBytes[i]);
  }
  for (int i = 0; i < data.length; i++) {
    chunk.setUint8(8 + i, data[i]);
  }

  final crcInput = Uint8List(4 + data.length);
  for (int i = 0; i < 4; i++) {
    crcInput[i] = typeBytes[i];
  }
  crcInput.setRange(4, crcInput.length, data);
  final crc = _crc32(crcInput);
  chunk.setUint32(8 + data.length, crc, Endian.big);

  return chunk.buffer.asUint8List();
}

extension on ByteData {
  void setUint8List(int offset, Uint8List data) {
    for (int i = 0; i < data.length; i++) {
      setUint8(offset + i, data[i]);
    }
  }
}

