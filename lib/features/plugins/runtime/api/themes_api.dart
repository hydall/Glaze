import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../../shared/theme/theme_preset.dart';
import '../../../../shared/theme/theme_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../providers/plugin_library_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'files_api.dart';
import 'library_io.dart';
import 'shapes.dart';

/// `glaze.themes.*` and `glaze.themes.assets.*` (files that belong to one
/// theme, e.g. images its CSS uses).
Map<String, PluginMethod> themesApi() => {
  'themes.list': libraryRead(PluginPermission.themesRead, _list),
  'themes.get': libraryRead(PluginPermission.themesRead, _get),
  'themes.find': libraryRead(PluginPermission.themesRead, _find),
  'themes.current': libraryRead(PluginPermission.themesRead, _current),
  'themes.create': libraryCreate(
    PluginPermission.themesCreate,
    _create,
    'plugins_consent_theme_create',
  ),
  'themes.update': libraryUpdate(
    PluginPermission.themesUpdate,
    _update,
    'plugins_consent_theme_update',
  ),
  'themes.remove': libraryDelete(
    PluginPermission.themesDelete,
    _remove,
    'plugins_consent_theme_remove',
  ),
  'themes.apply': libraryUpdate(
    PluginPermission.themesUpdate,
    _apply,
    'plugins_consent_theme_apply',
  ),
  'themes.import': libraryCreate(
    PluginPermission.themesCreate,
    _import,
    'plugins_consent_theme_import',
  ),
  'themes.export': libraryRead(PluginPermission.themesRead, _export),
  'themes.assets.list': libraryRead(PluginPermission.themesRead, _assetList),
  'themes.assets.load': libraryRead(PluginPermission.themesRead, _assetLoad),
  'themes.assets.save': libraryUpdate(
    PluginPermission.themesUpdate,
    _assetSave,
    'plugins_consent_theme_update',
  ),
  'themes.assets.rename': libraryUpdate(
    PluginPermission.themesUpdate,
    _assetRename,
    'plugins_consent_theme_update',
  ),
  'themes.assets.remove': libraryUpdate(
    PluginPermission.themesUpdate,
    _assetRemove,
    'plugins_consent_theme_update',
  ),
};

List<ThemePreset> _all(PluginCall c) => c.ref.read(themeProvider).presets;

ThemePreset? _byId(PluginCall c, Object? id) {
  final key = refId(id);
  return _all(c).where((t) => t.id == key).firstOrNull;
}

ThemePreset _requireEditable(PluginCall c, Object? id) {
  final t = _byId(c, id);
  if (t == null) throw PluginApiError('not_found', 'No theme ${refId(id)}');
  if (t.isBuiltIn) {
    throw const PluginApiError('read_only', 'Built-in themes cannot change');
  }
  return t;
}

Future<Object?> _list(PluginCall c) async => [
  for (final t in _all(c)) {'id': t.id, 'name': t.name, 'builtIn': t.isBuiltIn},
];

Future<Object?> _get(PluginCall c) async => _byId(c, c.arg(0))?.toJson();

Future<Object?> _current(PluginCall c) async =>
    c.ref.read(themeProvider).activePreset.toJson();

Future<Object?> _find(PluginCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  return [
    for (final t in _all(c))
      if (nameMatches(t.name, query, match)) t.toJson(),
  ];
}

Future<Object?> _create(PluginCall c) async {
  final data = c.mapArg(0);
  final theme = themePresetFromStoredJson({
    ...c.ref.read(themeProvider).activePreset.toJson(),
    ...data,
    'id': generateId(),
    'name': data['name'] ?? 'Theme',
  });
  await c.ref.read(themeProvider.notifier).importPreset(theme);
  return theme.id;
}

Future<Object?> _update(PluginCall c) async {
  final data = c.mapArg(0);
  final existing = _requireEditable(c, data['id']);
  final theme = themePresetFromStoredJson({
    ...existing.toJson(),
    ...data,
    'id': existing.id,
  });
  await c.ref.read(themeProvider.notifier).updatePreset(theme);
  return theme.id;
}

Future<Object?> _remove(PluginCall c) async {
  final t = _requireEditable(c, c.arg(0));
  await c.ref.read(themeProvider.notifier).deletePreset(t.id);
  final dir = await _assetsDir(c, t.id);
  if (await dir.exists()) await dir.delete(recursive: true);
  return t.id;
}

Future<Object?> _apply(PluginCall c) async {
  final t = _byId(c, c.arg(0));
  if (t == null) return null;
  await c.ref.read(themeProvider.notifier).applyPreset(t);
  return t.id;
}

Future<Object?> _import(PluginCall c) async {
  final json = await readImportSource(c);
  final theme = themePresetFromStoredJson({
    ...json,
    'id': generateId(),
    'name': json['name'] ?? 'Theme',
  });
  await c.ref.read(themeProvider.notifier).importPreset(theme);
  return theme.id;
}

Future<Object?> _export(PluginCall c) async {
  final t = _byId(c, c.arg(0));
  if (t == null) return null;
  return exportJson(c, t.toJson(), t.name);
}

/* ---------- assets ---------- */

Future<Directory> _assetsDir(PluginCall c, String themeId) async {
  final store = await c.ref.read(pluginStoreProvider.future);
  return Directory(
    p.join(
      store.dataRoot,
      '_theme_assets',
      themeId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'),
    ),
  );
}

Future<File> _asset(PluginCall c, String name) async {
  final theme = _byId(c, c.arg(0));
  if (theme == null) throw PluginApiError('not_found', 'No theme ${c.arg(0)}');
  if (name.isEmpty ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..')) {
    throw PluginApiError('invalid_arguments', 'Invalid asset name "$name"');
  }
  return File(p.join((await _assetsDir(c, theme.id)).path, name));
}

Future<Object?> _assetList(PluginCall c) async {
  final theme = _byId(c, c.arg(0));
  if (theme == null) return null;
  final dir = await _assetsDir(c, theme.id);
  if (!await dir.exists()) return <Object>[];
  final files = await dir.list().where((e) => e is File).cast<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      {
        'name': p.basename(f.path),
        'size': await f.length(),
        'mimeType': pluginMimeType(f.path),
      },
  ];
}

Future<Object?> _assetLoad(PluginCall c) async {
  final file = await _asset(c, c.requireString(1, 'name'));
  if (!await file.exists()) return null;
  return encodePluginContent(
    await file.readAsBytes(),
    c.mapArg(2)['encoding'] as String? ?? 'dataUrl',
    file.path,
  );
}

Future<Object?> _assetSave(PluginCall c) async {
  _requireEditable(c, c.arg(0));
  final file = await _asset(c, c.requireString(1, 'name'));
  final bytes = await decodePluginContent(
    c,
    c.arg(2),
    c.mapArg(3)['encoding'] as String?,
  );
  if (bytes.length > kPluginFileMaxBytes) {
    throw const PluginApiError('too_large', 'The file is too large');
  }
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  return p.basename(file.path);
}

Future<Object?> _assetRename(PluginCall c) async {
  _requireEditable(c, c.arg(0));
  final from = await _asset(c, c.requireString(1, 'name'));
  final to = await _asset(c, c.requireString(2, 'newName'));
  if (!await from.exists()) return null;
  await from.rename(to.path);
  return p.basename(to.path);
}

Future<Object?> _assetRemove(PluginCall c) async {
  _requireEditable(c, c.arg(0));
  final file = await _asset(c, c.requireString(1, 'name'));
  if (await file.exists()) await file.delete();
  return null;
}
