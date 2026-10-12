import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-plugin storage: the `localStorage` shim and `tavo.file.*`.
///
/// Files are private to the plugin (unlike Tavo, where chat files are shared
/// by every script in the chat). Virtual paths keep Tavo's shape:
/// `files/chat/<name>`, `files/global/<name>`, `files/tmp/<name>`.
class TavoFileStore {
  TavoFileStore({required this.dataDir});

  final String dataDir;
  static const maxStorageBytes = 2 * 1024 * 1024;
  static const scopes = {'chat', 'global', 'tmp'};

  File get _storageFile => File(p.join(dataDir, 'storage.json'));
  Future<void> _lock = Future.value();

  Future<Map<String, String>> readStorage() async {
    final file = _storageFile;
    if (!await file.exists()) return {};
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> updateStorage(void Function(Map<String, String>) change) {
    final run = _lock.then((_) async {
      final values = await readStorage();
      change(values);
      final encoded = jsonEncode(values);
      if (utf8.encode(encoded).length > maxStorageBytes) {
        throw StateError('Plugin storage exceeds $maxStorageBytes bytes');
      }
      await Directory(dataDir).create(recursive: true);
      final tmp = File('${_storageFile.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(_storageFile.path);
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Resolves a name or virtual path to a file inside this plugin's data.
  ({File file, String virtualPath}) resolve(
    String nameOrPath, {
    String? scope,
    required String? sessionId,
  }) {
    var name = nameOrPath;
    var effectiveScope = scope ?? 'chat';
    final match = RegExp(r'^files/(chat|global|tmp)/(.+)$').firstMatch(name);
    if (match != null) {
      effectiveScope = match.group(1)!;
      name = match.group(2)!;
    }
    if (!scopes.contains(effectiveScope)) {
      throw ArgumentError('Unsupported file scope "$effectiveScope"');
    }
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        name.contains('..')) {
      throw ArgumentError('Invalid file name "$nameOrPath"');
    }
    final String dir;
    if (effectiveScope == 'chat') {
      if (sessionId == null) throw StateError('No chat is open');
      dir = p.join(dataDir, 'files', 'chat', _safeSegment(sessionId));
    } else {
      dir = p.join(dataDir, 'files', effectiveScope);
    }
    return (
      file: File(p.join(dir, name)),
      virtualPath: 'files/$effectiveScope/$name',
    );
  }

  Directory scopeDir(String scope, String? sessionId) {
    if (scope == 'chat') {
      if (sessionId == null) throw StateError('No chat is open');
      return Directory(
        p.join(dataDir, 'files', 'chat', _safeSegment(sessionId)),
      );
    }
    return Directory(p.join(dataDir, 'files', scope));
  }

  static String _safeSegment(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}
