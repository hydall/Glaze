import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../compat/tavo/tavo_manifest_converter.dart';
import '../models/plugin_manifest.dart';
import 'plugin_manifest_parser.dart';

/// Upper bounds for an imported package; a package is a zip, so these guard
/// against archives that expand far beyond what a plugin needs.
const int kMaxPluginPackageBytes = 64 * 1024 * 1024;
const int kMaxPluginFiles = 2000;
const String kPluginManifestFile = 'plugin.json';

/// A validated, in-memory plugin package.
class PluginPackage {
  const PluginPackage({required this.manifest, required this.files});

  final PluginManifest manifest;

  /// Package-relative path → bytes. Always holds a `plugin.json`, also for
  /// converted packages.
  final Map<String, Uint8List> files;
}

/// Reads a `.glzp` (or a Tavo `.tpg`, converted on the way in): the manifest
/// at the root, safe paths only, and every file the manifest points at.
PluginPackage readPluginPackage(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const PluginManifestException('The file is not a plugin package');
  }

  final files = <String, Uint8List>{};
  var total = 0;
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = entry.name;
    if (name.startsWith('__MACOSX/') || name.endsWith('/.DS_Store')) continue;
    if (!isSafePluginPath(name)) {
      throw PluginManifestException(
        'The package contains an unsafe path: $name',
      );
    }
    final content = entry.readBytes();
    if (content == null) continue;
    total += content.length;
    if (total > kMaxPluginPackageBytes || files.length >= kMaxPluginFiles) {
      throw const PluginManifestException('The plugin package is too large');
    }
    files[name] = content;
  }

  _unwrapSingleFolder(files);

  final Map<String, dynamic> manifestJson;
  if (files.containsKey(kPluginManifestFile)) {
    manifestJson = _decode(files[kPluginManifestFile]!, kPluginManifestFile);
  } else if (files.containsKey(kTavoManifestFile)) {
    manifestJson = convertTavoManifest(
      _decode(files[kTavoManifestFile]!, kTavoManifestFile),
    );
    files[kPluginManifestFile] = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(manifestJson)),
    );
  } else {
    throw const PluginManifestException('plugin.json is missing');
  }
  final manifest = parsePluginManifest(manifestJson);

  void requireFile(String? path, String field) {
    if (path != null && !files.containsKey(path)) {
      throw PluginManifestException('$field points at a missing file: $path');
    }
  }

  requireFile(manifest.main, 'main');
  for (final p in manifest.panels) {
    requireFile(p.src, 'panels.${p.id}');
  }
  for (final h in manifest.fileHandlers) {
    for (final s in h.scripts) {
      requireFile(s, 'fileHandlers.${h.id}');
    }
  }
  for (final path in manifest.localeFiles.values) {
    requireFile(path, 'locales');
  }
  return PluginPackage(manifest: manifest, files: files);
}

Map<String, dynamic> _decode(Uint8List bytes, String name) {
  try {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is Map<String, dynamic>) return json;
  } catch (_) {
    // Reported below.
  }
  throw PluginManifestException('$name is not valid JSON');
}

/// Zipping the folder instead of its contents is a common authoring slip;
/// accept a single top-level folder holding the manifest.
void _unwrapSingleFolder(Map<String, Uint8List> files) {
  if (files.containsKey(kPluginManifestFile) ||
      files.containsKey(kTavoManifestFile)) {
    return;
  }
  final nested = files.keys.where(
    (k) =>
        k.endsWith('/$kPluginManifestFile') ||
        k.endsWith('/$kTavoManifestFile'),
  );
  final candidate = nested.length == 1 ? nested.first : null;
  final prefix = candidate?.substring(0, candidate.lastIndexOf('/') + 1);
  if (prefix == null ||
      prefix.split('/').where((s) => s.isNotEmpty).length != 1 ||
      !files.keys.every((k) => k.startsWith(prefix))) {
    return;
  }
  final stripped = {
    for (final e in files.entries) e.key.substring(prefix.length): e.value,
  };
  files
    ..clear()
    ..addAll(stripped);
}
