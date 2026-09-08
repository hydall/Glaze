import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/character.dart';
import '../utils/cast_helpers.dart';
import '../utils/id_generator.dart';
import '../utils/time_helpers.dart';
import 'image_storage_service.dart';
import 'png_text_extractor.dart';

class CharacterImportResult {
  final Character character;
  final bool hadAvatar;
  final Map<String, dynamic>? characterBookData;
  final List<GalleryImageData>? galleryImages;

  CharacterImportResult({
    required this.character,
    required this.hadAvatar,
    this.characterBookData,
    this.galleryImages,
  });
}

class GalleryImageData {
  final String label;
  final Uint8List bytes;
  final String ext;

  GalleryImageData({
    required this.label,
    required this.bytes,
    required this.ext,
  });
}

class CharacterImporter {
  final ImageStorageService _imageStorage;

  CharacterImporter(this._imageStorage);

  Future<CharacterImportResult> importFromFile(String filePath) async {
    final ext = p.extension(filePath).toLowerCase();
    final file = File(filePath);
    final bytes = await file.readAsBytes();

    if (ext == '.png') {
      return _importPng(bytes);
    } else if (ext == '.charx' || ext == '.zip') {
      return _importCharX(bytes);
    } else {
      return _importJson(bytes);
    }
  }

  Future<CharacterImportResult> importFromBytes(
    Uint8List bytes,
    String fileName,
  ) async {
    final ext = p.extension(fileName).toLowerCase();

    if (ext == '.png') {
      return _importPng(bytes);
    } else if (ext == '.charx' || ext == '.zip') {
      return _importCharX(bytes);
    } else {
      return _importJson(bytes);
    }
  }

  Future<CharacterImportResult> _importPng(Uint8List pngBytes) async {
    final rawData = extractCharacterDataFromPng(pngBytes);
    if (rawData == null) {
      throw FormatException('No character data found in PNG tEXt chunks');
    }

    final data = _normalizeCharacterData(rawData);
    _logCharacterBook('png', data);
    final character = await _saveCharacterWithAvatar(data, pngBytes);
    return CharacterImportResult(
      character: character,
      hadAvatar: true,
      characterBookData: data['character_book'] as Map<String, dynamic>?,
    );
  }

  Future<CharacterImportResult> _importJson(Uint8List jsonBytes) async {
    final jsonString = utf8.decode(jsonBytes);
    final rawJson = jsonDecode(jsonString) as Map<String, dynamic>;
    final data = _normalizeCharacterData(rawJson);
    _logCharacterBook('json', data);

    Uint8List? avatarBytes;
    final avatarSrc = data['avatar'] as String?;
    if (avatarSrc != null && avatarSrc.isNotEmpty) {
      avatarBytes = dataUrlToBytes(avatarSrc);
    }

    final character = await _saveCharacterWithAvatar(data, avatarBytes);
    return CharacterImportResult(
      character: character,
      hadAvatar: avatarBytes != null,
      characterBookData: data['character_book'] as Map<String, dynamic>?,
    );
  }

  Future<CharacterImportResult> _importCharX(Uint8List zipBytes) async {
    final archive = ZipDecoder().decodeBytes(_charXZipBytes(zipBytes));

    String? cardJsonContent;
    final assetFiles = <String, Uint8List>{};

    for (final file in archive) {
      if (file.isFile) {
        final content = Uint8List.fromList(file.content as List<int>);
        if (p.basename(file.name) == 'card.json') {
          cardJsonContent = utf8.decode(content);
        } else {
          assetFiles[file.name] = content;
        }
      }
    }

    if (cardJsonContent == null) {
      throw FormatException('No card.json found in CharX archive');
    }

    final rawJson = jsonDecode(cardJsonContent) as Map<String, dynamic>;
    final data = _normalizeCharacterData(rawJson);
    _logCharacterBook('charx', data);

    Uint8List? avatarBytes;
    final assets = data['assets'] as List<dynamic>?;
    if (assets != null) {
      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final type = assetMap['type'] as String?;
        final uri = assetMap['uri'] as String?;

        if (type == 'icon' && uri != null) {
          final zipPath = _resolveEmbeddedUri(uri);
          if (assetFiles.containsKey(zipPath)) {
            avatarBytes = assetFiles[zipPath]!;
            break;
          }
        }
      }
    }

    if (avatarBytes == null) {
      final avatarSrc = data['avatar'] as String?;
      if (avatarSrc != null && avatarSrc.isNotEmpty) {
        avatarBytes = dataUrlToBytes(avatarSrc);
      }
    }

    final galleryImages = <GalleryImageData>[];
    final extGallery = data['extensions'] is Map
        ? (data['extensions'] as Map)['gallery'] as List<dynamic>?
        : null;
    if (extGallery != null) {
      for (final g in extGallery) {
        final gMap = g as Map<String, dynamic>;
        final uri = gMap['uri'] as String?;
        if (uri != null) {
          final zipPath = _resolveEmbeddedUri(uri);
          if (assetFiles.containsKey(zipPath) &&
              assetFiles[zipPath]!.isNotEmpty) {
            final fileExt = p.extension(zipPath).replaceFirst('.', '');
            galleryImages.add(
              GalleryImageData(
                label: gMap['label'] as String? ?? '',
                bytes: assetFiles[zipPath]!,
                ext: fileExt.isEmpty ? 'png' : fileExt,
              ),
            );
          }
        }
      }
    }

    if (galleryImages.isEmpty && assets != null) {
      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final type = assetMap['type'] as String?;
        final uri = assetMap['uri'] as String?;
        if (type == 'gallery' && uri != null) {
          final zipPath = _resolveEmbeddedUri(uri);
          if (assetFiles.containsKey(zipPath) &&
              assetFiles[zipPath]!.isNotEmpty) {
            final fileExt = p.extension(zipPath).replaceFirst('.', '');
            galleryImages.add(
              GalleryImageData(
                label: assetMap['name'] as String? ?? '',
                bytes: assetFiles[zipPath]!,
                ext: fileExt.isEmpty ? 'png' : fileExt,
              ),
            );
          }
        }
      }
    }

    final character = await _saveCharacterWithAvatar(data, avatarBytes);
    return CharacterImportResult(
      character: character,
      hadAvatar: avatarBytes != null,
      characterBookData: data['character_book'] as Map<String, dynamic>?,
      galleryImages: galleryImages.isNotEmpty ? galleryImages : null,
    );
  }

  Uint8List _charXZipBytes(Uint8List bytes) {
    if (_hasZipSignature(bytes, 0)) return bytes;

    final isJpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    if (!isJpeg) return bytes;

    for (var i = 3; i <= bytes.length - 4; i++) {
      if (_hasZipSignature(bytes, i) &&
          i >= 2 &&
          bytes[i - 2] == 0xff &&
          bytes[i - 1] == 0xd9) {
        return Uint8List.sublistView(bytes, i);
      }
    }
    return bytes;
  }

  bool _hasZipSignature(Uint8List bytes, int offset) =>
      offset + 4 <= bytes.length &&
      bytes[offset] == 0x50 &&
      bytes[offset + 1] == 0x4b &&
      bytes[offset + 2] == 0x03 &&
      bytes[offset + 3] == 0x04;

  Map<String, dynamic> _normalizeCharacterData(Map<String, dynamic> json) {
    final spec = json['spec'] as String?;
    if (spec == 'chara_card_v2' || spec == 'chara_card_v3') {
      final data = json['data'] as Map<String, dynamic>?;
      if (data != null) return Map<String, dynamic>.from(data);
    }
    if (json.containsKey('name') || json.containsKey('data')) {
      if (json.containsKey('data') && json['data'] is Map) {
        return Map<String, dynamic>.from(json['data'] as Map);
      }
      return Map<String, dynamic>.from(json);
    }
    throw FormatException('Unknown character data format');
  }

  void _logCharacterBook(String source, Map<String, dynamic> data) {
    final book = data['character_book'];
    if (book == null) {
      debugPrint(
        '[character_import] source=$source name=${data['name']} character_book=null',
      );
      return;
    }
    if (book is! Map) {
      debugPrint(
        '[character_import] source=$source name=${data['name']} character_book_type=${book.runtimeType}',
      );
      return;
    }
    final entries = book['entries'];
    final entryCount = entries is List
        ? entries.length
        : entries is Map
        ? entries.length
        : 0;
    debugPrint(
      '[character_import] source=$source name=${data['name']} '
      'book_name=${book['name']} entries_type=${entries.runtimeType} '
      'entries=$entryCount',
    );
  }

  Future<Character> _saveCharacterWithAvatar(
    Map<String, dynamic> data,
    Uint8List? avatarBytes,
  ) async {
    final id = generateId();
    String? avatarPath;

    if (avatarBytes != null) {
      avatarPath = await _imageStorage.saveAvatar(id, avatarBytes);
    } else {
      final avatarSrc = data['avatar'] as String?;
      if (avatarSrc != null && avatarSrc.isNotEmpty) {
        avatarPath = await _imageStorage.saveAvatarFromDataUrl(id, avatarSrc);
      }
    }

    return Character(
      id: id,
      name: (data['name'] as String?) ?? 'Unknown',
      avatarPath: avatarPath,
      description: data['description'] as String?,
      personality: data['personality'] as String?,
      scenario: data['scenario'] as String?,
      firstMes: data['first_mes'] as String?,
      mesExample: data['mes_example'] as String?,
      systemPrompt: data['system_prompt'] as String?,
      postHistoryInstructions: data['post_history_instructions'] as String?,
      creator: data['creator'] as String?,
      creatorNotes: data['creator_notes'] as String?,
      color: data['color'] as String?,
      tags: toStringList(data['tags']),
      alternateGreetings: toStringList(data['alternate_greetings']),
      updatedAt: currentTimestampSeconds(),
      createdAt: currentTimestampSeconds(),
      fav: data['fav'] as bool? ?? false,
      extensions: _extractExtensions(data),
      characterVersion: data['character_version'] is String
          ? data['character_version'] as String
          : '1',
      depthPrompt: _extractDepthPrompt(data),
      depthPromptDepth: _extractDepthPromptDepth(data),
      depthPromptRole: _extractDepthPromptRole(data),
      world: _extractWorld(data),
      macroName: data['macro_name'] as String?,
    );
  }

  Map<String, dynamic> _extractExtensions(Map<String, dynamic> data) {
    return extractExtensionsJson(data);
  }

  String _extractDepthPrompt(Map<String, dynamic> data) {
    final ext = data['extensions'] is Map ? data['extensions'] as Map : null;
    final dp = ext?['depth_prompt'] is Map ? ext!['depth_prompt'] as Map : null;
    if (dp == null) return '';
    return dp['prompt'] is String ? dp['prompt'] as String : '';
  }

  int _extractDepthPromptDepth(Map<String, dynamic> data) {
    final ext = data['extensions'] is Map ? data['extensions'] as Map : null;
    final dp = ext?['depth_prompt'] is Map ? ext!['depth_prompt'] as Map : null;
    if (dp == null) return 4;
    final d = dp['depth'];
    if (d is int) return d;
    if (d is num) return d.toInt();
    return 4;
  }

  String _extractDepthPromptRole(Map<String, dynamic> data) {
    final ext = data['extensions'] is Map ? data['extensions'] as Map : null;
    final dp = ext?['depth_prompt'] is Map ? ext!['depth_prompt'] as Map : null;
    if (dp == null) return 'system';
    return dp['role'] is String ? dp['role'] as String : 'system';
  }

  String? _extractWorld(Map<String, dynamic> data) {
    final ext = data['extensions'] is Map ? data['extensions'] as Map : null;
    final world = ext?['world'];
    return world is String && world.isNotEmpty ? world : null;
  }

  String _resolveEmbeddedUri(String uri) {
    if (uri.startsWith('embedded://')) {
      return uri.substring('embedded://'.length);
    }
    if (uri.startsWith('embeded://')) {
      return uri.substring('embeded://'.length);
    }
    if (uri.startsWith('__asset:')) {
      return uri.substring('__asset:'.length);
    }
    return uri;
  }
}
