import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/cast_helpers.dart';
import '../utils/platform_paths.dart';
import '../application/sync_repo_interfaces.dart';

/// Shorter-side target (px) of the pre-generated list/card thumbnails.
/// Changing this must be paired with a bump of the thumbnail migration key (see
/// [_kThumbMigrationKey]) so stale thumbnails are regenerated.
const int kThumbnailShortSide = 768;

/// Upper bound for the long side. Without this, unusually tall or wide images
/// can produce thumbnails too large for mobile image decoders and GPU textures.
const int kThumbnailLongSide = 4096;

/// JPEG quality for the generated thumbnails.
const int _kThumbnailQuality = 92;

String imageExtensionForBytes(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'jpg';
  }
  if (bytes.length >= 12) {
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'gif';
  }
  return 'png';
}

/// SharedPreferences flag: once set, the previous-generation thumbnails have
/// been wiped. Bumping the version (v4 → v5 …) forces a one-time re-clear so a
/// new [kThumbnailShortSide] / resize policy takes effect for existing
/// libraries. Pair with [_kThumbBackfillKey] so the wiped thumbnails are
/// regenerated in the background.
const String _kThumbMigrationKey = 'gz_thumb_v6_migrated';

/// SharedPreferences flag guarding the one-time background thumbnail backfill.
const String _kThumbBackfillKey = 'gz_thumb_v6_backfilled';

const String _kThumbMigrationMarker = '.thumbnails-v6-migrated';
const String _kThumbRefreshMarker = '.thumbnails-v6-refresh-required';

/// Runs in a background isolate and scales without upscaling or changing the
/// aspect ratio. Both axes are bounded to keep extreme images mobile-safe.
Uint8List? resizeAvatarBytes(
  Uint8List imageBytes,
  int maxShortSide, [
  int maxLongSide = kThumbnailLongSide,
]) {
  try {
    final image = img.decodeImage(imageBytes);
    if (image == null) return null;
    final shortSide = image.width <= image.height ? image.width : image.height;
    final longSide = image.width >= image.height ? image.width : image.height;
    final shortScale = maxShortSide / shortSide;
    final longScale = maxLongSide / longSide;
    final scale = [1.0, shortScale, longScale].reduce((a, b) => a < b ? a : b);
    final scaled = scale < 1
        ? img.copyResize(
            image,
            width: (image.width * scale).round().clamp(1, maxLongSide),
            height: (image.height * scale).round().clamp(1, maxLongSide),
          )
        : image;
    return Uint8List.fromList(
      img.encodeJpg(scaled, quality: _kThumbnailQuality),
    );
  } catch (_) {
    return null;
  }
}

class ImageStorageService implements SyncImageStore {
  final String baseDir;

  ImageStorageService(this.baseDir);

  static Future<ImageStorageService> create() async {
    final baseDir = await getAppDataDir();
    final service = ImageStorageService(baseDir);
    await service.migrateOldThumbnails();
    return service;
  }

  Future<void> migrateOldThumbnails([SharedPreferences? prefsArg]) async {
    final prefs = prefsArg ?? await SharedPreferences.getInstance();
    final marker = File(p.join(baseDir, _kThumbMigrationMarker));
    if (await marker.exists()) return;

    // The Windows ProductName determines the preferences directory. A renamed
    // executable must not replay a destructive thumbnail migration against the
    // stable Glaze data directory just because its preference flag moved.
    if (prefs.getBool(_kThumbMigrationKey) != true) {
      await File(
        p.join(baseDir, _kThumbRefreshMarker),
      ).writeAsString('pending', flush: true);
    }
    await prefs.setBool(_kThumbMigrationKey, true);
    // Also repairs files removed by an interrupted legacy migration. Existing
    // thumbnails are skipped unless a real schema refresh is pending.
    await prefs.setBool(_kThumbBackfillKey, false);
    await marker.writeAsString('done', flush: true);
  }

  /// One-time background pass that regenerates thumbnails for any [avatarPaths]
  /// that lost theirs to the resolution bump wipe. Decoding is offloaded to a
  /// short-lived isolate per image so the UI stays smooth; the whole pass is
  /// guarded by a SharedPreferences flag so it only runs once per bump.
  ///
  /// Returns the number of thumbnails (re)generated.
  Future<int> backfillMissingThumbnails(Iterable<String?> avatarPaths) async {
    final prefs = await SharedPreferences.getInstance();
    final refreshMarker = File(p.join(baseDir, _kThumbRefreshMarker));
    final refreshExisting = await refreshMarker.exists();
    if (!refreshExisting && prefs.getBool(_kThumbBackfillKey) == true) return 0;

    final dir = Directory(p.join(baseDir, 'thumbnails'));
    if (!await dir.exists()) await dir.create(recursive: true);

    var made = 0;
    var complete = true;
    for (final avatarPath in avatarPaths) {
      if (avatarPath == null || avatarPath.isEmpty) continue;
      if (!refreshExisting && thumbnailPath(avatarPath) != null) continue;

      final resolvedPath = absolutePath(avatarPath) ?? avatarPath;
      final avatarFile = File(resolvedPath);
      if (!await avatarFile.exists()) {
        complete = false;
        continue;
      }

      try {
        final bytes = await avatarFile.readAsBytes();
        final thumbnail = await Isolate.run(
          () => resizeAvatarBytes(bytes, kThumbnailShortSide),
        );
        if (thumbnail == null) {
          complete = false;
          continue;
        }
        final name = p.basenameWithoutExtension(resolvedPath);
        await File(p.join(dir.path, '$name.jpg')).writeAsBytes(thumbnail);
        made++;
      } catch (_) {
        complete = false;
      }
    }

    if (complete) {
      await prefs.setBool(_kThumbBackfillKey, true);
      if (await refreshMarker.exists()) await refreshMarker.delete();
    }
    return made;
  }

  Future<String> saveAvatar(String characterId, Uint8List imageBytes) async {
    final dir = Directory(p.join(baseDir, 'avatars'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final cleanBytes = _stripPngTextChunks(imageBytes);
    final path = p.join(dir.path, '$characterId.png');
    await File(path).writeAsBytes(cleanBytes);
    await saveThumbnail(characterId, cleanBytes);
    return path;
  }

  Future<String?> saveAvatarFromDataUrl(
    String characterId,
    String dataUrl,
  ) async {
    final bytes = dataUrlToBytes(dataUrl);
    if (bytes == null) return null;
    return saveAvatar(characterId, bytes);
  }

  Future<String?> saveThumbnail(
    String characterId,
    Uint8List imageBytes,
  ) async {
    final dir = Directory(p.join(baseDir, 'thumbnails'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final thumbnail = await _resizeImage(imageBytes, kThumbnailShortSide);
    if (thumbnail == null) return null;
    final path = p.join(dir.path, '$characterId.jpg');
    await File(path).writeAsBytes(thumbnail);
    return path;
  }

  Future<String?> ensureThumbnailForAvatarPath(String? avatarPath) async {
    if (avatarPath == null || avatarPath.isEmpty) return null;
    final resolvedPath = absolutePath(avatarPath) ?? avatarPath;
    final avatarFile = File(resolvedPath);
    if (!await avatarFile.exists()) return null;

    final bytes = await avatarFile.readAsBytes();
    final thumbnail = await _resizeImage(bytes, kThumbnailShortSide);
    if (thumbnail == null) return null;

    final dir = Directory(p.join(baseDir, 'thumbnails'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final name = p.basenameWithoutExtension(resolvedPath);
    final path = p.join(dir.path, '$name.jpg');
    await File(path).writeAsBytes(thumbnail);
    return path;
  }

  Future<void> deleteAvatar(String characterId) async {
    final avatarPath = p.join(baseDir, 'avatars', '$characterId.png');
    final file = File(avatarPath);
    if (await file.exists()) await file.delete();
    final thumbPath = p.join(baseDir, 'thumbnails', '$characterId.jpg');
    final thumbFile = File(thumbPath);
    if (await thumbFile.exists()) await thumbFile.delete();
  }

  String? thumbnailPath(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return null;
    final name = p.basenameWithoutExtension(avatarPath);
    final thumb = p.join(baseDir, 'thumbnails', '$name.jpg');
    return File(thumb).existsSync() ? thumb : null;
  }

  @override
  Future<String> saveBytes(
    Uint8List bytes,
    String subfolder,
    String filename,
    String ext,
  ) async {
    final dir = Directory(p.join(baseDir, subfolder));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final path = p.join(dir.path, '$filename.$ext');
    await File(path).writeAsBytes(bytes);
    return path;
  }

  @override
  String? absolutePath(String? relativePath) {
    if (relativePath == null) return null;
    if (relativePath.isEmpty) return relativePath;
    if (!File(relativePath).isAbsolute) {
      return p.join(baseDir, relativePath);
    }
    // Rebase stale iOS containers and sibling desktop build channels.
    final rebased = _rebaseOntoBaseDir(relativePath);
    return rebased ?? relativePath;
  }

  /// Resolves [absPath] against the current Glaze data directory when the
  /// equivalent file exists, otherwise retains an existing source path.
  String? _rebaseOntoBaseDir(String absPath) {
    final normalized = absPath.replaceAll('\\', '/');
    final match = RegExp(
      r'/(?:Glaze|Glaze-staging|Glaze-nightly)/',
      caseSensitive: false,
    ).allMatches(normalized).lastOrNull;
    if (match != null) {
      final suffix = normalized.substring(match.end);
      if (suffix.isNotEmpty) {
        final rebased = p.join(baseDir, suffix);
        if (File(rebased).existsSync()) return rebased;
      }
    }
    return File(absPath).existsSync() ? absPath : null;
  }

  /// Resizes off the UI isolate.
  ///
  /// Decoding a full-size card PNG and re-encoding it as a JPEG costs hundreds
  /// of milliseconds and a decode buffer many times the file size. Doing that
  /// inline meant one dropped frame — and one large allocation — per imported
  /// card; a mass import piled up hundreds of them. `Isolate.run` hands those
  /// buffers back the moment the worker exits (the thumbnail backfill above
  /// already worked this way).
  Future<Uint8List?> _resizeImage(Uint8List imageBytes, int maxDimension) =>
      Isolate.run(() => resizeAvatarBytes(imageBytes, maxDimension));

  Uint8List _stripPngTextChunks(Uint8List pngBytes) {
    if (pngBytes.length < 8) return pngBytes;
    final sig = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    for (int i = 0; i < 8; i++) {
      if (pngBytes[i] != sig[i]) return pngBytes;
    }
    final data = ByteData.sublistView(pngBytes);
    final out = BytesBuilder();
    out.add(pngBytes.sublist(0, 8));
    int offset = 8;
    bool stripped = false;
    while (offset < pngBytes.length - 4) {
      final length = data.getUint32(offset, Endian.big);
      final type = String.fromCharCodes(
        pngBytes.sublist(offset + 4, offset + 8),
      );
      if (type == 'tEXt' || type == 'zTXt' || type == 'iTXt') {
        stripped = true;
        offset += 12 + length;
        continue;
      }
      out.add(pngBytes.sublist(offset, offset + 12 + length));
      offset += 12 + length;
      if (type == 'IEND') break;
    }
    return stripped ? out.toBytes() : pngBytes;
  }
}
