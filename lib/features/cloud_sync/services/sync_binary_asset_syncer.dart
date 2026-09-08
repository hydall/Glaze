import 'dart:io';

import '../../../core/models/gallery_entry.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';
import '../sync_repo_interfaces.dart';

/// Handles push/pull of binary avatar and gallery image assets during cloud
/// sync. Extracted from [SyncEngine] to keep the engine focused on entity
/// manifest diffing.
class SyncBinaryAssetSyncer {
  final CloudAdapter _adapter;
  final SyncCharacterStore _characterRepo;
  final SyncPersonaStore _personaRepo;
  final SyncImageStore _imageStorage;

  SyncBinaryAssetSyncer(
    this._adapter,
    this._characterRepo,
    this._personaRepo,
    this._imageStorage,
  );

  Future<void> pushCharacterAvatar(String charId) async {
    try {
      final c = await _characterRepo.getById(charId);
      if (c?.avatarPath == null) return;
      final file = File(_imageStorage.absolutePath(c!.avatarPath)!);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final ext = c.avatarPath!.split('.').last;
      await _adapter.uploadBinary(
        galleryCloudPath(charId, 'avatar', ext),
        bytes,
      );
    } catch (_) {}
  }

  Future<void> pullCharacterAvatar(String charId) async {
    try {
      final c = await _characterRepo.getById(charId);
      if (c == null) return;

      await sanitizeInvalidAvatarPath(charId);
      final current = await _characterRepo.getById(charId);
      if (current == null) return;

      for (final ext in ['png', 'jpg', 'webp', 'gif']) {
        try {
          final imgCloudPath = galleryCloudPath(charId, 'avatar', ext);
          final bytes = await _adapter.downloadBinary(imgCloudPath);
          if (bytes.isNotEmpty) {
            final localPath = await _imageStorage.saveBytes(
              bytes,
              'avatars',
              charId,
              ext,
            );
            await _characterRepo.put(current.copyWith(avatarPath: localPath));
            return;
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> pushPersonaAvatar(String personaId) async {
    try {
      final p = await _personaRepo.getById(personaId);
      if (p?.avatarPath == null) return;
      final file = File(_imageStorage.absolutePath(p!.avatarPath)!);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final ext = p.avatarPath!.split('.').last;
      await _adapter.ensureFolder('$cloudBase/persona_avatars/$personaId');
      await _adapter.uploadBinary(
        personaAvatarCloudPath(personaId, ext),
        bytes,
      );
    } catch (_) {}
  }

  Future<void> pullPersonaAvatar(String personaId) async {
    try {
      final p = await _personaRepo.getById(personaId);
      if (p == null) return;

      for (final ext in ['png', 'jpg', 'webp', 'gif']) {
        try {
          final imgCloudPath = personaAvatarCloudPath(personaId, ext);
          final bytes = await _adapter.downloadBinary(imgCloudPath);
          if (bytes.isNotEmpty) {
            final relativePath = await _imageStorage.saveBytes(
              bytes,
              'avatars',
              personaId,
              ext,
            );
            await _personaRepo.put(p.copyWith(avatarPath: relativePath));
            return;
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> pushCharacterGallery(String charId) async {
    try {
      final c = await _characterRepo.getById(charId);
      if (c == null) return;
      await _adapter.ensureFolder('$cloudBase/gallery/$charId');
      for (final entry in c.gallery) {
        final absPath = _imageStorage.absolutePath(entry.imagePath);
        if (absPath == null) continue;
        final file = File(absPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final ext = entry.imagePath.split('.').last;
        await _adapter.uploadBinary(
          galleryCloudPath(charId, entry.id, ext),
          bytes,
        );
      }
    } catch (_) {}
  }

  Future<void> pullCharacterGallery(String charId) async {
    try {
      final c = await _characterRepo.getById(charId);
      if (c == null) return;

      final updatedGallery = <GalleryEntry>[];
      for (final entry in c.gallery) {
        var pulled = false;
        for (final ext in ['png', 'jpg', 'webp', 'gif']) {
          try {
            final imgCloudPath = galleryCloudPath(charId, entry.id, ext);
            final bytes = await _adapter.downloadBinary(imgCloudPath);
            if (bytes.isNotEmpty) {
              final destPath = await _imageStorage.saveBytes(
                bytes,
                'gallery/$charId',
                entry.id,
                ext,
              );
              updatedGallery.add(entry.copyWith(imagePath: destPath));
              pulled = true;
              break;
            }
          } catch (_) {}
        }
        if (!pulled) {
          final absPath = _imageStorage.absolutePath(entry.imagePath);
          if (absPath != null && await File(absPath).exists()) {
            updatedGallery.add(entry);
          }
        }
      }

      if (updatedGallery.length != c.gallery.length ||
          !_galleriesEqual(updatedGallery, c.gallery)) {
        await _characterRepo.put(c.copyWith(gallery: updatedGallery));
      }
    } catch (_) {}
  }

  /// Clears the avatar path on disk when the local file is missing so that
  /// cloud pull can replace it without a stale path blocking the download.
  Future<void> sanitizeInvalidAvatarPath(String charId) async {
    final c = await _characterRepo.getById(charId);
    if (c == null || c.avatarPath == null || c.avatarPath!.isEmpty) return;
    if (_localAvatarFileExists(c.avatarPath)) return;
    await _characterRepo.put(c.copyWith(avatarPath: null));
  }

  bool _localAvatarFileExists(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return false;
    final abs = _imageStorage.absolutePath(avatarPath);
    if (abs == null) return false;
    return File(abs).existsSync();
  }

  bool _galleriesEqual(List<GalleryEntry> a, List<GalleryEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].imagePath != b[i].imagePath) return false;
    }
    return true;
  }
}
