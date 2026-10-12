import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../utils/platform_paths.dart';

/// Kind of file the Logs screen lists.
enum DiagnosticsFileKind { session, crash }

class DiagnosticsFile {
  final DiagnosticsFileKind kind;
  final String path;
  final DateTime modified;
  final int bytes;

  const DiagnosticsFile({
    required this.kind,
    required this.path,
    required this.modified,
    required this.bytes,
  });

  String get name => p.basename(path);

  /// When the session started / the crash was detected, read back from the
  /// file name ([DiagnosticsStore.stamp]); the modification time otherwise.
  DateTime get createdAt =>
      DiagnosticsStore.parseStamp(p.basenameWithoutExtension(path)) ?? modified;
}

/// Where logs and crash reports live, and the housekeeping around them.
///
/// ```
/// <data root>/logs/
///   session.json              how the last run is doing (SessionTracker)
///   sessions/<stamp>.log      one file per app launch
///   crashes/<stamp>.txt       one report per detected crash
/// ```
///
/// Kept out of the backup and cloud-sync trees, which only pick up the folders
/// they name.
abstract final class DiagnosticsStore {
  static const maxSessions = 20;
  static const maxCrashes = 30;

  static Future<String> rootDir() async =>
      p.join(await getAppDataDir(), 'logs');

  static Future<Directory> sessionsDir() => _ensure('sessions');

  static Future<Directory> crashesDir() => _ensure('crashes');

  static Future<Directory> _ensure(String name) async {
    final dir = Directory(p.join(await rootDir(), name));
    await dir.create(recursive: true);
    return dir;
  }

  /// File-name-safe local timestamp: `2026-10-06_10-07-33`.
  static String stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
  }

  static DateTime? parseStamp(String name) {
    final m = RegExp(
      r'^(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)-(\d\d)',
    ).firstMatch(name);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
    return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  }

  /// Newest first.
  static Future<List<DiagnosticsFile>> list(DiagnosticsFileKind kind) async {
    final dir = kind == DiagnosticsFileKind.session
        ? await sessionsDir()
        : await crashesDir();
    final files = <DiagnosticsFile>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      files.add(
        DiagnosticsFile(
          kind: kind,
          path: entity.path,
          modified: stat.modified,
          bytes: stat.size,
        ),
      );
    }
    // Stamps sort chronologically as strings; a suffix (`_2`) keeps
    // same-second files in creation order.
    files.sort((a, b) => b.name.compareTo(a.name));
    return files;
  }

  /// Drops the oldest files beyond the caps. [keep] is never deleted — the
  /// current session's log, which is still being written.
  static Future<void> prune({String? keep}) async {
    for (final (kind, cap) in [
      (DiagnosticsFileKind.session, maxSessions),
      (DiagnosticsFileKind.crash, maxCrashes),
    ]) {
      final files = await list(kind);
      for (final file in files.skip(cap)) {
        if (file.path == keep) continue;
        await _tryDelete(file.path);
      }
    }
  }

  static Future<void> delete(DiagnosticsFile file) => _tryDelete(file.path);

  /// Deletes everything except [keep].
  static Future<void> clear({String? keep}) async {
    for (final kind in DiagnosticsFileKind.values) {
      for (final file in await list(kind)) {
        if (file.path == keep) continue;
        await _tryDelete(file.path);
      }
    }
  }

  /// Zips every log and crash report into [targetDir] and returns the path.
  static Future<String> zipAll(String targetDir) async {
    final root = await rootDir();
    final out = p.join(targetDir, 'glaze-logs-${stamp(DateTime.now())}.zip');
    final encoder = ZipFileEncoder()..create(out);
    for (final kind in DiagnosticsFileKind.values) {
      for (final file in await list(kind)) {
        await encoder.addFile(
          File(file.path),
          p.relative(file.path, from: root).replaceAll('\\', '/'),
        );
      }
    }
    await encoder.close();
    return out;
  }

  static Future<void> _tryDelete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Locked (Windows) or already gone.
    }
  }

  /// The `Kind:` line [CrashDetector] writes at the top of a report.
  static Future<String?> crashKind(String path) async {
    try {
      final raf = await File(path).open();
      try {
        final head = utf8.decode(await raf.read(512), allowMalformed: true);
        return RegExp(r'^Kind:\s+(\S+)', multiLine: true).firstMatch(head)?[1];
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Last [maxLines] lines of a text file, read from the end so a large log
  /// is not loaded whole.
  static Future<String> tail(
    String path, {
    int maxLines = 400,
    int maxBytes = 256 * 1024,
  }) async {
    final file = File(path);
    if (!await file.exists()) return '';
    final length = await file.length();
    final start = length > maxBytes ? length - maxBytes : 0;
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(length - start);
      // Lenient: the chunk edge can cut a multi-byte character in half.
      final lines = utf8.decode(bytes, allowMalformed: true).split('\n');
      if (start > 0 && lines.isNotEmpty) lines.removeAt(0); // partial line
      return lines.length <= maxLines
          ? lines.join('\n')
          : lines.sublist(lines.length - maxLines).join('\n');
    } finally {
      await raf.close();
    }
  }
}
