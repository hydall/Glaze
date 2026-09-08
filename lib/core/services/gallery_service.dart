import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../db/repositories/character_repo.dart';
import '../models/gallery_entry.dart';
import '../services/image_storage_service.dart';

class GalleryService {
  final CharacterRepo _characterRepo;
  final ImageStorageService _imageStorage;

  GalleryService(this._characterRepo, this._imageStorage);

  Future<List<GalleryEntry>> getGallery(String charId) async {
    final c = await _characterRepo.getById(charId);
    return c?.gallery ?? [];
  }

  Future<GalleryEntry> addImage(
    String charId,
    String imagePath, {
    String? label,
  }) async {
    final sourceFile = File(_imageStorage.absolutePath(imagePath) ?? imagePath);
    if (!await sourceFile.exists()) {
      throw Exception('Image file not found: $imagePath');
    }

    final ext = p.extension(imagePath).replaceFirst('.', '');
    final id = 'gal_${DateTime.now().millisecondsSinceEpoch}';
    final destPath = await _imageStorage.saveBytes(
      await sourceFile.readAsBytes(),
      'gallery/$charId',
      id,
      ext,
    );

    final entry = GalleryEntry(
      id: id,
      characterId: charId,
      imagePath: destPath,
      label: label,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    final c = await _characterRepo.getById(charId);
    if (c != null) {
      await _characterRepo.put(c.copyWith(gallery: [...c.gallery, entry]));
    }

    return entry;
  }

  Future<GalleryEntry> addImageBytes(
    String charId,
    List<int> bytes,
    String ext, {
    String? label,
  }) async {
    final id = 'gal_${DateTime.now().millisecondsSinceEpoch}';
    final destPath = await _imageStorage.saveBytes(
      bytes is! Uint8List ? Uint8List.fromList(bytes) : bytes,
      'gallery/$charId',
      id,
      ext,
    );

    final entry = GalleryEntry(
      id: id,
      characterId: charId,
      imagePath: destPath,
      label: label,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    final c = await _characterRepo.getById(charId);
    if (c != null) {
      await _characterRepo.put(c.copyWith(gallery: [...c.gallery, entry]));
    }

    return entry;
  }

  Future<void> deleteImage(String charId, String entryId) async {
    final c = await _characterRepo.getById(charId);
    if (c == null) return;

    final entry = c.gallery.where((e) => e.id == entryId).firstOrNull;
    if (entry != null) {
      final file = File(
        _imageStorage.absolutePath(entry.imagePath) ?? entry.imagePath,
      );
      if (await file.exists()) {
        await file.delete();
      }
    }

    await _characterRepo.put(
      c.copyWith(gallery: c.gallery.where((e) => e.id != entryId).toList()),
    );
  }

  Future<void> setAsAvatar(String charId, String entryId) async {
    final c = await _characterRepo.getById(charId);
    if (c == null) return;

    final entry = c.gallery.where((e) => e.id == entryId).firstOrNull;
    if (entry == null) return;

    final sourceFile = File(
      _imageStorage.absolutePath(entry.imagePath) ?? entry.imagePath,
    );
    if (!await sourceFile.exists()) return;

    final bytes = await sourceFile.readAsBytes();
    final avatarPath = await _imageStorage.saveAvatar(charId, bytes);
    await _imageStorage.saveThumbnail(charId, bytes);

    await _characterRepo.put(c.copyWith(avatarPath: avatarPath));
  }
}
