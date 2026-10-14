import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-plugin storage: the `localStorage` shim and `glaze.files.*`.
///
/// Files are private to the plugin. Virtual paths are
/// `files/chat/<name>` (per chat), `files/global/<name>` and
/// `files/tmp/<name>` (cleared on the next start).
class PluginFileStore {
  PluginFileStore({required this.dataDir});

  final String dataDir;
  /// Cap of the `localStorage` shim: keys and values together, in UTF-8.
  /// The shim refuses a write past it the way a browser does, so a plugin
  /// learns at once that its data was not kept.
  static const maxStorageBytes = 10 * 1024 * 1024;

  static int storageBytes(Map<String, String> values) {
    var total = 0;
    for (final e in values.entries) {
      total += utf8.encode(e.key).length + utf8.encode(e.value).length;
    }
    return total;
  }

  /// Cap on everything a plugin keeps in its files, across all scopes.
  static const maxFilesBytes = 256 * 1024 * 1024;
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
      if (storageBytes(values) > maxStorageBytes) {
        throw StateError('Plugin storage exceeds $maxStorageBytes bytes');
      }
      final encoded = jsonEncode(values);
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
      dir = p.join(dataDir, 'files', 'chat', chatSegment(sessionId));
    } else {
      dir = p.join(dataDir, 'files', effectiveScope);
    }
    return (
      file: File(p.join(dir, name)),
      virtualPath: 'files/$effectiveScope/$name',
    );
  }

  Directory scopeDir(String scope, String? sessionId) {
    if (!scopes.contains(scope)) {
      throw ArgumentError('Unsupported file scope "$scope"');
    }
    if (scope == 'chat') {
      if (sessionId == null) throw StateError('No chat is open');
      return Directory(
        p.join(dataDir, 'files', 'chat', chatSegment(sessionId)),
      );
    }
    return Directory(p.join(dataDir, 'files', scope));
  }

  /// Bytes the plugin's files take, all scopes together.
  Future<int> usedBytes() async {
    final dir = Directory(p.join(dataDir, 'files'));
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// The folder name of a chat's files.
  static String chatSegment(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}
