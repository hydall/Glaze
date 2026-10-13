import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/installed_plugin.dart';
import '../compat/tavo/tavo_manifest_converter.dart';
import '../models/plugin_manifest.dart';
import 'plugin_manifest_parser.dart';
import 'plugin_package_reader.dart';

/// On-disk home of installed plugins.
///
/// ```
/// <root>/registry.json          install order, enabled flag, settings
/// <root>/<id>/...               unpacked package (read-only at runtime)
/// <dataRoot>/<id>/...           plugin-owned data (storage shim, files)
/// ```
class PluginStore {
  PluginStore({required this.root, required this.dataRoot});

  final String root;
  final String dataRoot;

  File get _registryFile => File(p.join(root, 'registry.json'));

  String packageDir(String id) => p.join(root, id);
  String dataDir(String id) => p.join(dataRoot, id);

  Future<List<Map<String, dynamic>>> _readRecords() async {
    final file = _registryFile;
    if (!await file.exists()) return [];
    try {
      final json = jsonDecode(await file.readAsString());
      final list = json is Map ? json['plugins'] : null;
      if (list is! List) return [];
      return [
        for (final r in list)
          if (r is Map && r['id'] is String) Map<String, dynamic>.from(r),
      ];
    } catch (e) {
      debugPrint('[PluginStore] registry unreadable: $e');
      return [];
    }
  }

  Future<void> _writeRecords(List<Map<String, Object?>> records) async {
    await Directory(root).create(recursive: true);
    final tmp = File('${_registryFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'version': 1, 'plugins': records}),
      flush: true,
    );
    await tmp.rename(_registryFile.path);
  }

  /// Every installed plugin whose package still parses, in install order.
  Future<List<InstalledPlugin>> loadAll() async {
    final out = <InstalledPlugin>[];
    for (final record in await _readRecords()) {
      final id = record['id'] as String;
      try {
        out.add(await _load(id, record));
      } catch (e) {
        debugPrint('[PluginStore] skipping $id: $e');
      }
    }
    return out;
  }

  Future<InstalledPlugin> _load(String id, Map<String, dynamic> record) async {
    final dir = packageDir(id);
    final manifest = await _readManifest(dir);
    final catalogs = <String, Map<String, String>>{};
    for (final e in manifest.localeFiles.entries) {
      try {
        final json = jsonDecode(
          await File(p.join(dir, e.value)).readAsString(),
        );
        if (json is Map) {
          catalogs[e.key] = {
            for (final m in json.entries)
              if (m.key is String && m.value is String)
                m.key as String: m.value as String,
          };
        }
      } catch (err) {
        debugPrint('[PluginStore] $id catalog ${e.key} unreadable: $err');
      }
    }
    final config = record['config'];
    final grants = record['grants'];
    return InstalledPlugin(
      manifest: manifest,
      directory: dir,
      enabled: record['enabled'] == true,
      installedAt: (record['installedAt'] as num?)?.toInt() ?? 0,
      config: config is Map ? Map<String, Object?>.from(config) : const {},
      catalogs: catalogs,
      grants: grants is List ? {for (final g in grants) '$g'} : const {},
    );
  }

  /// Reads `plugin.json`, converting a package installed before it existed.
  Future<PluginManifest> _readManifest(String dir) async {
    final own = File(p.join(dir, kPluginManifestFile));
    if (await own.exists()) {
      return parsePluginManifest(jsonDecode(await own.readAsString()));
    }
    final converted = convertTavoManifest(
      jsonDecode(await File(p.join(dir, kTavoManifestFile)).readAsString()),
    );
    await own.writeAsString(jsonEncode(converted));
    return parsePluginManifest(converted);
  }

  /// Clears every plugin's `files/tmp` (temporary files last one run).
  Future<void> clearTemporaryFiles() async {
    final root = Directory(dataRoot);
    if (!await root.exists()) return;
    await for (final dir in root.list()) {
      if (dir is! Directory) continue;
      final tmp = Directory(p.join(dir.path, 'files', 'tmp'));
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  /// Unpacks [package], replacing an older version of the same plugin and
  /// keeping its settings and enabled state.
  Future<InstalledPlugin> install(PluginPackage package) async {
    final id = package.manifest.id;
    final staging = Directory(p.join(root, '.staging-$id'));
    if (await staging.exists()) await staging.delete(recursive: true);
    for (final e in package.files.entries) {
      final file = File(p.joinAll([staging.path, ...e.key.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(e.value);
    }
    final target = Directory(packageDir(id));
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);

    final records = await _readRecords();
    final existing = records.where((r) => r['id'] == id).firstOrNull;
    final record = <String, Object?>{
      'id': id,
      'enabled': existing == null ? true : existing['enabled'] == true,
      'installedAt': DateTime.now().millisecondsSinceEpoch,
      'config': existing?['config'] ?? const <String, Object?>{},
      'grants': existing?['grants'] ?? const <String>[],
    };
    if (existing == null) {
      records.add(record);
    } else {
      records[records.indexOf(existing)] = record;
    }
    await _writeRecords(records);
    return _load(id, record);
  }

  Future<void> save(InstalledPlugin plugin) async {
    final records = await _readRecords();
    final index = records.indexWhere((r) => r['id'] == plugin.id);
    if (index < 0) return;
    records[index] = plugin.toRecord();
    await _writeRecords(records);
  }

  Future<void> uninstall(String id) async {
    final records = await _readRecords()
      ..removeWhere((r) => r['id'] == id);
    await _writeRecords(records);
    for (final path in [packageDir(id), dataDir(id)]) {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Reads a file from an installed package; null when it is missing or the
  /// path is not package-relative.
  Future<Uint8List?> readPackageFile(String id, String path) async {
    if (!isSafePluginPath(path)) return null;
    final file = File(p.joinAll([packageDir(id), ...path.split('/')]));
    return await file.exists() ? file.readAsBytes() : null;
  }
}
