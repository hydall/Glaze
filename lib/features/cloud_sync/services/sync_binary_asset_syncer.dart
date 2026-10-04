import 'dart:io';

import '../../../core/models/gallery_entry.dart';
import '../../../core/services/preset_image_paths.dart';
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
  final SyncPresetStore _presetRepo;
  final SyncImageStore _imageStorage;

  SyncBinaryAssetSyncer(
    this._adapter,
    this._characterRepo,
    this._personaRepo,
    this._presetRepo,
    this._imageStorage,
  );

  /// Extensions probed when pulling a binary whose stored extension is unknown
  /// on this device.
  static const _imageExtensions = ['png', 'jpg', 'webp', 'gif'];

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

      for (final ext in _imageExtensions) {
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

      for (final ext in _imageExtensions) {
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

  /// Uploads every preset cover that lives on this device.
  ///
  /// Presets travel as one `theme_presets` singleton, so this runs once for the
  /// whole list instead of per entry. Covers pointing at a bundled `assets/...`
  /// path are skipped — they ship with the app on every device.
  Future<void> pushPresetImages() async {
    try {
      final presets = await _presetRepo.getAll();
      var folderEnsured = false;
      for (final preset in presets) {
        final path = preset.imagePath;
        if (path == null || path.isEmpty || _isBundledAsset(path)) continue;
        final absPath = _imageStorage.absolutePath(path);
        if (absPath == null) continue;
        final file = File(absPath);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (!folderEnsured) {
          await _adapter.ensureFolder('$cloudBase/preset_images');
          folderEnsured = true;
        }
        await _adapter.ensureFolder('$cloudBase/preset_images/${preset.id}');
        await _adapter.uploadBinary(
          presetImageCloudPath(preset.id, _extensionOf(path)),
          bytes,
        );
      }
    } catch (_) {}
  }

  /// Downloads the cover of every preset that references a file this device
  /// does not have yet.
  ///
  /// The stored path is relative and carries its own version suffix, so it is
  /// valid on every device and never rewritten here — the pull only has to put
  /// the bytes where the path already points. A cover that fails to download is
  /// left alone: the next push from the device that owns the file must not be
  /// told the image is gone, and the UI simply shows no cover meanwhile.
  Future<void> pullPresetImages() async {
    try {
      final presets = await _presetRepo.getAll();
      for (final preset in presets) {
        final path = preset.imagePath;
        if (path == null || path.isEmpty || _isBundledAsset(path)) continue;
        final storageId = presetImageStorageIdOf(path);
        if (storageId == null) continue;
        final absPath = _imageStorage.absolutePath(path);
        if (absPath != null && await File(absPath).exists()) continue;

        for (final ext in _extensionsToProbe(path)) {
          try {
            final bytes = await _adapter.downloadBinary(
              presetImageCloudPath(preset.id, ext),
            );
            if (bytes.isEmpty) continue;
            await _imageStorage.saveBytes(bytes, 'avatars', storageId, ext);
            // The pushed and stored extensions agree in practice (covers are
            // always written as PNG), but honour a mismatch rather than leaving
            // the preset pointing at a file saved under another name.
            final relative = presetImageRelativePath(storageId, ext);
            if (relative != path) {
              await _presetRepo.put(preset.copyWith(imagePath: relative));
            }
            break;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Bundled covers (a cloned featured preset) exist in every install's asset
  /// bundle, so they are neither uploaded nor downloaded.
  bool _isBundledAsset(String path) => isPresetAssetImage(path);

  String _extensionOf(String path) => path.split('.').last;

  /// The extension the path already claims, tried first, then the rest.
  List<String> _extensionsToProbe(String path) {
    final own = _extensionOf(path).toLowerCase();
    if (!_imageExtensions.contains(own)) return _imageExtensions;
    return [own, ..._imageExtensions.where((e) => e != own)];
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
        for (final ext in _imageExtensions) {
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
