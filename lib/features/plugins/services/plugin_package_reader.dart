import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/plugin_manifest.dart';
import 'plugin_manifest_parser.dart';

/// Upper bounds for an imported package; a `.tpg` is a zip, so these guard
/// against archives that expand far beyond what a plugin needs.
const int kMaxPluginPackageBytes = 64 * 1024 * 1024;
const int kMaxPluginFiles = 2000;

/// A validated, in-memory `.tpg` package.
class PluginPackage {
  const PluginPackage({required this.manifest, required this.files});

  final PluginManifest manifest;

  /// Package-relative path → bytes.
  final Map<String, Uint8List> files;
}

/// Reads a `.tpg` (zip) and checks it the way Tavo's installer does:
/// `manifest.json` at the root, safe paths only, and every file the manifest
/// points at present.
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

  // Zipping the folder instead of its contents is a common authoring slip;
  // accept a single top-level folder holding the manifest.
  if (!files.containsKey('manifest.json')) {
    final nested = files.keys.where((k) => k.endsWith('/manifest.json'));
    final candidate = nested.length == 1 ? nested.first : null;
    final prefix = candidate?.substring(
      0,
      candidate.length - 'manifest.json'.length,
    );
    if (prefix == null ||
        prefix.split('/').where((s) => s.isNotEmpty).length != 1 ||
        !files.keys.every((k) => k.startsWith(prefix))) {
      throw const PluginManifestException('manifest.json is missing');
    }
    final stripped = {
      for (final e in files.entries) e.key.substring(prefix.length): e.value,
    };
    files
      ..clear()
      ..addAll(stripped);
  }

  final Object? json;
  try {
    json = jsonDecode(utf8.decode(files['manifest.json']!));
  } catch (_) {
    throw const PluginManifestException('manifest.json is not valid JSON');
  }
  final manifest = parsePluginManifest(json);

  void requireFile(String? path, String field) {
    if (path != null && !files.containsKey(path)) {
      throw PluginManifestException('$field points at a missing file: $path');
    }
  }

  requireFile(manifest.entry, 'entry');
  for (final f in manifest.fragments) {
    requireFile(f.src, 'htmlFragments.${f.id}');
  }
  for (final path in manifest.localeResources.values) {
    requireFile(path, 'localization.resources');
  }
  return PluginPackage(manifest: manifest, files: files);
}
