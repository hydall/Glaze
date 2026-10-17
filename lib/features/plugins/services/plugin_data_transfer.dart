import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/installed_plugin.dart';
import '../runtime/plugin_file_store.dart';
import '../runtime/plugin_variable_store.dart';
import 'plugin_store.dart';

/// `format` of a plugin data file.
const kPluginDataFormat = 'glaze-plugin-data';

/// Why a plugin data file was not taken.
enum PluginDataError {
  /// Not JSON, or not a plugin data file.
  notPluginData,

  /// Written by a newer Glaze.
  newerVersion,

  /// Another plugin's data.
  otherPlugin,

  /// Bigger than the plugin may keep.
  tooBig,
}

class PluginDataException implements Exception {
  const PluginDataException(this.error, [this.detail]);

  final PluginDataError error;

  /// The other plugin's id for [PluginDataError.otherPlugin].
  final String? detail;

  @override
  String toString() =>
      'PluginDataException(${error.name}${detail == null ? '' : ': $detail'})';
}

/// What an import brought back.
class PluginDataImport {
  const PluginDataImport({required this.config, required this.skippedChats});

  /// The plugin's settings to save.
  final Map<String, Object?> config;

  /// Chats in the file this device does not have; their variables were
  /// left out.
  final int skippedChats;
}

/// Everything one plugin keeps, as one JSON file: its settings, its
/// `localStorage`, its variables (global and per chat) and its files
/// (`global` and per chat, base64). Permissions stay with the device.
///
/// ```
/// {"format": "glaze-plugin-data", "version": 1,
///  "plugin": {"id", "version"}, "exportedAt",
///  "settings": {key: value}, "storage": {key: string},
///  "variables": {"global": {...},
///                "chats": {sessionId: {"chat": {...}, "messages": {...}}}},
///  "files": {"global/<name>" | "chat/<chat>/<name>": base64}}
/// ```
class PluginDataTransfer {
  PluginDataTransfer({required this.store, required this.variables});

  static const version = 1;

  final PluginStore store;
  final PluginVariableStore variables;

  Future<Map<String, Object?>> export(InstalledPlugin plugin) async {
    final id = plugin.id;
    return {
      'format': kPluginDataFormat,
      'version': version,
      'plugin': {'id': id, 'version': plugin.manifest.version},
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'settings': plugin.config,
      'storage': await _files(id).readStorage(),
      'variables': {
        'global': await variables.read(id, 'global', null),
        'chats': await variables.readChats(id),
      },
      'files': await _readFiles(id),
    };
  }

  /// Replaces [plugin]'s data with [json]'s. Everything is checked before
  /// anything is written.
  Future<PluginDataImport> import(InstalledPlugin plugin, Object? json) async {
    if (json is! Map || json['format'] != kPluginDataFormat) {
      throw const PluginDataException(PluginDataError.notPluginData);
    }
    final v = json['version'];
    if (v is! int || v > version) {
      throw const PluginDataException(PluginDataError.newerVersion);
    }
    final from = _map(json['plugin'])['id'];
    if (from != plugin.id) {
      throw PluginDataException(PluginDataError.otherPlugin, '$from');
    }

    final keys = {
      for (final f in plugin.manifest.settings)
        if (f.key != null) f.key!,
    };
    final config = {
      for (final e in _map(json['settings']).entries)
        if (keys.contains(e.key)) e.key: e.value,
    };
    final storage = {
      for (final e in _map(json['storage']).entries)
        if (e.value is String) e.key: e.value as String,
    };
    if (PluginFileStore.storageBytes(storage) >
        PluginFileStore.maxStorageBytes) {
      throw const PluginDataException(PluginDataError.tooBig);
    }
    final vars = _map(json['variables']);
    final global = _map(vars['global']);
    final chats = {
      for (final e in _map(vars['chats']).entries)
        if (e.value is Map) e.key: _map(e.value),
    };
    bool fits(Object? root, int max) =>
        utf8.encode(jsonEncode(root)).length <= max;
    if (!fits(global, kPluginGlobalVariableMaxBytes) ||
        chats.values.any(
          (c) => c.values.any((root) => !fits(root, kPluginVariableMaxBytes)),
        )) {
      throw const PluginDataException(PluginDataError.tooBig);
    }
    final files = <String, List<int>>{};
    var bytes = 0;
    for (final e in _map(json['files']).entries) {
      final path = e.key;
      final data = e.value;
      if (data is! String || !_validFilePath(path)) {
        throw const PluginDataException(PluginDataError.notPluginData);
      }
      try {
        files[path] = base64Decode(data);
      } on FormatException {
        throw const PluginDataException(PluginDataError.notPluginData);
      }
      bytes += files[path]!.length;
    }
    if (bytes > PluginFileStore.maxFilesBytes) {
      throw const PluginDataException(PluginDataError.tooBig);
    }

    final id = plugin.id;
    await _files(id).updateStorage(
      (s) => s
        ..clear()
        ..addAll(storage),
    );
    await variables.update(
      id,
      'global',
      null,
      (root) => root
        ..clear()
        ..addAll(global),
    );
    final skipped = await variables.replaceChats(id, chats);
    await _writeFiles(id, files);
    return PluginDataImport(config: config, skippedChats: skipped);
  }

  PluginFileStore _files(String id) =>
      PluginFileStore(dataDir: store.dataDir(id));

  Directory _filesDir(String id) =>
      Directory(p.join(store.dataDir(id), 'files'));

  /// `global` and `chat` files; `tmp` is gone by the next start anyway.
  Future<Map<String, String>> _readFiles(String id) async {
    final root = _filesDir(id);
    final out = <String, String>{};
    for (final scope in const ['global', 'chat']) {
      final dir = Directory(p.join(root.path, scope));
      if (!await dir.exists()) continue;
      final files = await dir
          .list(recursive: true, followLinks: false)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final path = p.posix.joinAll(
          p.split(p.relative(f.path, from: root.path)),
        );
        if (_validFilePath(path)) {
          out[path] = base64Encode(await f.readAsBytes());
        }
      }
    }
    return out;
  }

  Future<void> _writeFiles(String id, Map<String, List<int>> files) async {
    final root = _filesDir(id);
    for (final scope in const ['global', 'chat']) {
      final dir = Directory(p.join(root.path, scope));
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    for (final e in files.entries) {
      final file = File(p.joinAll([root.path, ...e.key.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(e.value, flush: true);
    }
  }

  /// `global/<name>` or `chat/<chat>/<name>`, each part a plain name.
  static bool _validFilePath(String path) {
    final parts = path.split('/');
    final ok = switch (parts) {
      ['global', _] => true,
      ['chat', _, _] => true,
      _ => false,
    };
    return ok &&
        parts.every(
          (x) =>
              x.isNotEmpty &&
              x != '.' &&
              !x.contains('..') &&
              !x.contains('\\') &&
              !x.contains(':'),
        );
  }

  static Map<String, dynamic> _map(Object? x) =>
      x is Map ? Map<String, dynamic>.from(x) : <String, dynamic>{};
}
