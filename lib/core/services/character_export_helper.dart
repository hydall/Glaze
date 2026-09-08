import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import '../models/character.dart';
import '../state/lorebook_provider.dart';
import '../utils/platform_paths.dart';
import 'character_book_converter.dart';
import 'character_exporter.dart';
import 'file_export_service.dart';

/// Exports a single [character] in [format] (`png` | `json` | `zip`), bundling
/// any character-scoped lorebooks, and returns the saved file path.
///
/// Shared by the single-card export menu and the multi-select mass export so
/// both build the SillyTavern V2 payload identically.
Future<String> exportCharacterToFile({
  required WidgetRef ref,
  required Character character,
  required String format,
}) async {
  final tmpDir = await getTemporaryDirectory();
  final outputDir = tmpDir.path;

  final characterBookData = _buildCharacterBookData(ref, character.id);

  final safeName = (character.name.isEmpty ? 'character' : character.name)
      .replaceAll(RegExp(r'[/\\?%*:|"<>\.]'), '-')
      .trim();

  if (format == 'png') {
    final avatarBytes = await _resolveAvatarBytes(character);
    final result = await exportCharacterAsPng(
      character: character,
      avatarBytes: avatarBytes,
      outputDir: outputDir,
      includeCharacterBook: true,
      characterBookData: characterBookData,
    );
    final bytes = await File(result.filePath).readAsBytes();
    return FileExportService.exportBytes(
      bytes: bytes,
      filename: '$safeName.png',
      subfolder: 'characters',
    );
  } else if (format == 'zip') {
    final avatarBytes = await _resolveAvatarBytes(character);
    final galleryEntries = character.gallery;
    final galleryBytesList = <Uint8List>[];
    for (final entry in galleryEntries) {
      final file = File(
        resolveGlazeFilePath(entry.imagePath) ?? entry.imagePath,
      );
      galleryBytesList.add(
        await file.exists() ? await file.readAsBytes() : Uint8List(0),
      );
    }
    final validGallery = <int>[];
    for (int i = 0; i < galleryEntries.length; i++) {
      if (galleryBytesList[i].isNotEmpty) validGallery.add(i);
    }
    final filteredEntries = validGallery.map((i) => galleryEntries[i]).toList();
    final filteredBytes = validGallery.map((i) => galleryBytesList[i]).toList();

    final result = await exportCharacterAsZip(
      character: character,
      avatarBytes: avatarBytes,
      outputDir: outputDir,
      characterBookData: characterBookData,
      gallery: filteredEntries,
      galleryBytes: filteredBytes,
    );
    final bytes = await File(result.filePath).readAsBytes();
    return FileExportService.exportBytes(
      bytes: bytes,
      filename: '$safeName.zip',
      subfolder: 'characters',
    );
  } else {
    final result = await exportCharacterAsJson(
      character: character,
      outputDir: outputDir,
      includeCharacterBook: true,
      characterBookData: characterBookData,
    );
    final jsonStr = await File(result.filePath).readAsString();
    return FileExportService.export(
      data: jsonStr,
      filename: '$safeName.json',
      subfolder: 'characters',
    );
  }
}

/// Merges all character-scoped lorebooks for [characterId] into a single V2
/// `character_book` payload, or null when there are none.
Map<String, dynamic>? _buildCharacterBookData(
  WidgetRef ref,
  String characterId,
) {
  final lorebooks = ref.read(lorebooksProvider).value ?? [];
  final charLorebooks = lorebooks.where(
    (lb) =>
        lb.activationScope == 'character' &&
        lb.activationTargetId == characterId,
  );
  if (charLorebooks.isEmpty) return null;

  final merged = <String, dynamic>{
    'name': charLorebooks.first.name,
    'entries': <Map<String, dynamic>>[],
  };
  for (final lb in charLorebooks) {
    final bookJson = lorebookToCharacterBookJson(lb);
    (merged['entries'] as List<dynamic>).addAll(
      bookJson['entries'] as Iterable<dynamic>,
    );
    if (lb != charLorebooks.first) {
      merged['name'] = '${merged['name']}, ${lb.name}';
    }
  }
  return merged;
}

Future<Uint8List> _resolveAvatarBytes(Character character) async {
  final path = character.avatarPath;
  if (path != null && path.isNotEmpty) {
    final resolved = resolveGlazeFilePath(path);
    if (resolved != null && File(resolved).existsSync()) {
      return File(resolved).readAsBytes();
    }
  }
  return generatePlaceholderAvatar(character.name);
}
