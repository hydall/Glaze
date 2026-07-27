import 'dart:io';
import 'package:path/path.dart' as p;
// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import '../constants/build_channel.dart';

/// Cached Glaze data root, populated on the first [getAppDataDir] call (which
/// happens at startup via ImageStorageService.create / AppDatabase open).
/// Used by [resolveGlazeFilePath] so widgets can rebase stale absolute paths
/// without an async lookup.
String? _cachedAppDataDir;

String? get cachedAppDataDir => _cachedAppDataDir;

Future<String> getAppDataDir() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getApplicationDocumentsDirectory();
    final base = p.join(dir.path, 'Glaze');
    _cachedAppDataDir = base;
    return base;
  }
  final base = _desktopDataDir();
  _cachedAppDataDir = base;
  return base;
}

/// Resolves a stored avatar/gallery/etc. path for display.
///
/// iOS changes the app sandbox container UUID on every reinstall/OS update, so
/// absolute paths persisted by an older build (e.g.
/// `.../Application/<OLD_UUID>/Documents/Glaze/avatars/x.png`) stop existing
/// even though the files survive under the *new* container. This rebases any
/// absolute path that lives under a `Glaze` data root onto the current
/// [cachedAppDataDir]. Relative paths are joined onto the current base. When no
/// base is cached yet (very early startup) the input is returned unchanged.
String? resolveGlazeFilePath(String? path) {
  if (path == null || path.isEmpty) return path;
  final base = _cachedAppDataDir;
  if (base == null) return path;

  if (!p.isAbsolute(path)) {
    return p.join(base, path);
  }
  // Absolute: if it already exists, keep it. Otherwise try to rebase onto the
  // current base by the last data-root marker.
  if (File(path).existsSync()) return path;

  final normalized = path.replaceAll('\\', '/');
  // This channel's folder first, then the bare "Glaze" root, so a path written
  // by a stable build — or by any build from before the channels got their own
  // desktop data folders — still rebases. The set collapses to one entry on
  // stable and on mobile, where both names are the same.
  for (final marker in {'/$glazeDataFolderName/', '/Glaze/'}) {
    final idx = normalized.lastIndexOf(marker);
    if (idx < 0) continue;
    final suffix = normalized.substring(idx + marker.length);
    if (suffix.isEmpty) continue;
    return p.join(base, suffix);
  }
  return path;
}

/// Returns the on-disk path to the 512px thumbnail JPG for a stored avatar
/// path when that thumbnail exists, otherwise the resolved full-resolution
/// avatar path (or `null` when there is no avatar).
///
/// Lists (character grid, folder cards, chat history) should prefer this over
/// [resolveGlazeFilePath] so that scrolling decodes small square JPGs instead
/// of the multi-megabyte source PNGs — the latter causes visible jank and
/// delayed "pop-in" the first time each card scrolls into view.
String? resolveGlazeThumbnailPath(String? avatarPath) {
  final resolved = resolveGlazeFilePath(avatarPath);
  if (resolved == null || resolved.isEmpty) return resolved;
  final name = p.basenameWithoutExtension(resolved);
  // avatars/<id>.png -> <base>/thumbnails/<id>.jpg
  final base = p.dirname(p.dirname(resolved));
  final thumb = p.join(base, 'thumbnails', '$name.jpg');
  if (File(thumb).existsSync()) return thumb;
  return resolved;
}

String _desktopDataDir() {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA']!;
    return p.join(appData, glazeDataFolderName);
  } else if (Platform.isLinux) {
    final xdg = Platform.environment['XDG_DATA_HOME'] ??
        p.join(Platform.environment['HOME']!, '.local', 'share');
    return p.join(xdg, glazeDataFolderName);
  } else if (Platform.isMacOS) {
    return p.join(Platform.environment['HOME']!, 'Library',
        'Application Support', glazeDataFolderName);
  }
  throw UnsupportedError('Platform not supported yet');
}
