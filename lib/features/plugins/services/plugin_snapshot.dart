import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'plugin_manifest_parser.dart';
import 'plugin_permission_settler.dart';
import 'plugin_store.dart';

/// The installed plugins as they leave the device for a backup or for
/// cloud sync: packages, the registry, and what each plugin keeps (its
/// `localStorage`, global variables, files, settings). Chat and message
/// variables live in the chat rows and travel with the chats.
///
/// Left behind: temporary files, half-done installs and, for sync, the
/// request and network logs of this device. Permissions never travel; see
/// [PluginPermissionSettler].
class PluginSnapshot {
  PluginSnapshot(this.store);

  final PluginStore store;

  /// Folder of the packages in a backup archive.
  static const backupPackages = 'plugins';

  /// Folder of the plugin data in a backup archive.
  static const backupData = 'plugin_data';

  /// What a plugin did on this device, kept per plugin.
  static const deviceLogs = {'history.json', 'network.json'};

  static const _sharedFile = '_shared_variables.json';

  // ── Backup ──────────────────────────────────────────────────────────────

  /// Every plugin file a backup keeps, keyed by its path in the archive.
  Future<Map<String, File>> backupFiles() async {
    final out = <String, File>{};
    for (final (rel, file) in await _list(store.root)) {
      if (_keepPackageFile(rel)) out['$backupPackages/$rel'] = file;
    }
    for (final (rel, file) in await _list(store.dataRoot)) {
      if (_keepDataFile(rel, logs: true)) out['$backupData/$rel'] = file;
    }
    return out;
  }

  /// Where the archive entry [archivePath] goes on this device; null when it
  /// is not a plugin file or its path is unsafe.
  String? backupTarget(String archivePath) {
    for (final (prefix, root) in [
      (backupPackages, store.root),
      (backupData, store.dataRoot),
    ]) {
      if (!archivePath.startsWith('$prefix/')) continue;
      final rel = archivePath.substring(prefix.length + 1);
      if (!isSafePluginPath(rel)) return null;
      return p.joinAll([root, ...rel.split('/')]);
    }
    return null;
  }

  /// Replaces every plugin with those [write] puts on disk (the files of a
  /// backup, through [backupTarget]). Permissions are settled after.
  Future<void> restoreBackup(Future<void> Function() write) async {
    final settler = PluginPermissionSettler(store);
    final before = await settler.capture();
    for (final path in [store.root, store.dataRoot]) {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    await write();
    await settler.settleRegistry(before);
  }

  // ── Sync ────────────────────────────────────────────────────────────────

  /// The plugins as one sync entity: each record without its permissions
  /// and with a hash of the plugin's files, in install order, plus the
  /// variables plugins share.
  Future<Map<String, dynamic>> syncPayload() async {
    final items = <Map<String, Object?>>[];
    for (final record in await store.readRecords()) {
      final id = record['id'] as String;
      if (!_isSafeId(id) || !await Directory(store.packageDir(id)).exists()) {
        continue;
      }
      items.add({
        'record': {
          for (final e in record.entries)
            if (!kPluginPermissionFields.contains(e.key)) e.key: e.value,
        },
        'hash': await filesHash(id),
      });
    }
    final shared = File(p.join(store.dataRoot, _sharedFile));
    return {
      'items': items,
      'shared': await shared.exists() ? await shared.readAsString() : null,
    };
  }

  /// Hash of what of plugin [id] travels in sync.
  Future<String> filesHash(String id) async {
    final out = _DigestSink();
    final input = sha256.startChunkedConversion(out);
    for (final (prefix, rel, file) in await _syncFiles(id)) {
      input.add(utf8.encode('$prefix/$rel'));
      input.add(const [0]);
      final bytes = await file.readAsBytes();
      input.add(utf8.encode('${bytes.length}'));
      input.add(const [0]);
      input.add(bytes);
    }
    input.close();
    return out.value.toString();
  }

  /// Plugin [id]'s package and data as a zip: `package/...` and `data/...`.
  Future<Uint8List> pack(String id) async {
    final archive = Archive();
    for (final (prefix, rel, file) in await _syncFiles(id)) {
      archive.addFile(
        ArchiveFile.bytes('$prefix/$rel', await file.readAsBytes()),
      );
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Makes this device's plugins those of [payload]: plugins whose files
  /// differ are fetched with [download] (a zip from [pack]) and replaced,
  /// plugins it does not list are removed. Every download is done before
  /// anything is changed.
  Future<void> applySync(
    Map<String, dynamic> payload,
    Future<Uint8List> Function(String id) download,
  ) async {
    final items = payload['items'];
    if (items is! List) return;
    final records = <Map<String, dynamic>>[];
    final fetched = <String, Map<String, List<int>>>{};
    for (final item in items) {
      if (item is! Map) continue;
      final record = item['record'];
      final hash = item['hash'];
      if (record is! Map || hash is! String) continue;
      final id = record['id'];
      if (id is! String || !_isSafeId(id)) continue;
      records.add(Map<String, dynamic>.from(record));
      final installed = await Directory(store.packageDir(id)).exists();
      if (installed && await filesHash(id) == hash) continue;
      fetched[id] = _unpack(await download(id));
    }

    final settler = PluginPermissionSettler(store);
    final before = await settler.capture();
    final keep = {for (final r in records) r['id'] as String};
    for (final id in before.keys) {
      if (!keep.contains(id)) await _remove(id, logs: false);
    }
    for (final e in fetched.entries) {
      await _remove(e.key, logs: true);
      for (final f in e.value.entries) {
        final target = _syncTarget(e.key, f.key);
        if (target == null) continue;
        final file = File(target);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(f.value, flush: true);
      }
    }
    final shared = File(p.join(store.dataRoot, _sharedFile));
    final sharedJson = payload['shared'];
    if (sharedJson is String) {
      await shared.parent.create(recursive: true);
      await shared.writeAsString(sharedJson, flush: true);
    } else if (await shared.exists()) {
      await shared.delete();
    }
    await settler.writeSettled(Future.value(records), before);
  }

  // ── Files ───────────────────────────────────────────────────────────────

  /// Files of plugin [id] that sync carries, sorted: `package` and `data`.
  Future<List<(String, String, File)>> _syncFiles(String id) async {
    final out = <(String, String, File)>[];
    for (final (rel, file) in await _list(store.packageDir(id))) {
      if (!rel.endsWith('.tmp')) out.add(('package', rel, file));
    }
    for (final (rel, file) in await _list(store.dataDir(id))) {
      if (_keepDataFile('$id/$rel', logs: false)) out.add(('data', rel, file));
    }
    return out;
  }

  Map<String, List<int>> _unpack(Uint8List bytes) {
    final out = <String, List<int>>{};
    for (final f in ZipDecoder().decodeBytes(bytes).files) {
      if (!f.isFile) continue;
      final content = f.readBytes();
      if (content != null) out[f.name] = content;
    }
    return out;
  }

  String? _syncTarget(String id, String name) {
    for (final (prefix, root) in [
      ('package', store.packageDir(id)),
      ('data', store.dataDir(id)),
    ]) {
      if (!name.startsWith('$prefix/')) continue;
      final rel = name.substring(prefix.length + 1);
      if (!isSafePluginPath(rel)) return null;
      return p.joinAll([root, ...rel.split('/')]);
    }
    return null;
  }

  /// Deletes plugin [id]'s package and data; with [logs], this device's
  /// logs of it stay.
  Future<void> _remove(String id, {required bool logs}) async {
    final package = Directory(store.packageDir(id));
    if (await package.exists()) await package.delete(recursive: true);
    final data = Directory(store.dataDir(id));
    if (!await data.exists()) return;
    if (!logs) {
      await data.delete(recursive: true);
      return;
    }
    await for (final e in data.list(followLinks: false)) {
      if (e is File && deviceLogs.contains(p.basename(e.path))) continue;
      await e.delete(recursive: true);
    }
  }

  /// Files under [root], as posix paths relative to it.
  static Future<List<(String, File)>> _list(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return const [];
    final out = <(String, File)>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.posix.joinAll(p.split(p.relative(e.path, from: root)));
      out.add((rel, e));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// A file under the packages root: not an install in progress.
  static bool _keepPackageFile(String rel) =>
      !rel.startsWith('.staging-') && !rel.endsWith('.tmp');

  /// A file under the data root (`<id>/...` or a shared file): not a
  /// temporary file, and a device log only with [logs].
  static bool _keepDataFile(String rel, {required bool logs}) {
    if (rel.endsWith('.tmp')) return false;
    final parts = rel.split('/');
    if (parts.length >= 3 && parts[1] == 'files' && parts[2] == 'tmp') {
      return false;
    }
    if (!logs && parts.length == 2 && deviceLogs.contains(parts[1])) {
      return false;
    }
    return true;
  }

  static bool _isSafeId(String id) =>
      isSafePluginPath(id) && !id.contains('/') && !id.startsWith('.');
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
