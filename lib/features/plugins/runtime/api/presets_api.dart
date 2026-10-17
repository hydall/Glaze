import '../../../../core/import/silly_tavern_preset_parser.dart';
import '../../../../core/models/preset.dart';
import '../../../../core/state/shared_prefs_provider.dart';
import '../../../../core/state/active_selection_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../presets/preset_export.dart';
import '../../../presets/preset_list_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'library_io.dart';
import 'shapes.dart';

/// `glaze.presets.*` (prompt presets; objects are Glaze presets).
Map<String, PluginMethod> presetsApi() => {
  'presets.list': libraryRead(PluginPermission.presetsRead, _list),
  'presets.get': libraryRead(PluginPermission.presetsRead, _get),
  'presets.find': libraryRead(PluginPermission.presetsRead, _find),
  'presets.create': libraryCreate(
    PluginPermission.presetsCreate,
    _create,
    'plugins_consent_preset_create',
  ),
  'presets.update': libraryUpdate(
    PluginPermission.presetsUpdate,
    _update,
    'plugins_consent_preset_update',
  ),
  'presets.remove': libraryDelete(
    PluginPermission.presetsDelete,
    _remove,
    'plugins_consent_preset_remove',
  ),
  'presets.import': libraryCreate(
    PluginPermission.presetsCreate,
    _import,
    'plugins_consent_preset_import',
  ),
  'presets.export': libraryRead(PluginPermission.presetsRead, _export),
  'presets.setDefault': libraryUpdate(
    PluginPermission.presetsUpdate,
    _setDefault,
    'plugins_consent_preset_default',
  ),
};

Future<List<Preset>> _all(PluginCall c) =>
    c.ref.read(presetListProvider.future);

Future<Preset?> _byId(PluginCall c, Object? id) async {
  final key = refId(id);
  return (await _all(c)).where((p) => p.id == key).firstOrNull;
}

Future<Object?> _list(PluginCall c) async => [
  for (final p in await _all(c)) {'id': p.id, 'name': p.name},
];

Future<Object?> _get(PluginCall c) async =>
    (await _byId(c, c.arg(0)))?.toJson();

Future<Object?> _find(PluginCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  return [
    for (final p in await _all(c))
      if (nameMatches(p.name, query, match)) p.toJson(),
  ];
}

Future<Object?> _create(PluginCall c) async {
  final data = c.mapArg(0);
  if (data['name'] is! String) {
    throw const PluginApiError('invalid_arguments', 'name is required');
  }
  final preset = Preset.fromJson({
    ...data,
    'id': generateId(),
    'createdAt': DateTime.now().millisecondsSinceEpoch,
  });
  await c.ref.read(presetListProvider.notifier).add(preset);
  return preset.id;
}

Future<Object?> _update(PluginCall c) async {
  final data = c.mapArg(0);
  final existing = await _byId(c, data['id']);
  if (existing == null) {
    throw PluginApiError('not_found', 'No preset ${data['id']}');
  }
  final next = Preset.fromJson({
    ...existing.toJson(),
    ...data,
    'id': existing.id,
  });
  await c.ref.read(presetListProvider.notifier).updatePreset(next);
  return next.id;
}

Future<Object?> _remove(PluginCall c) async {
  final p = await _byId(c, c.arg(0));
  if (p == null) return null;
  await c.ref.read(presetListProvider.notifier).remove(p.id);
  return p.id;
}

Future<Object?> _import(PluginCall c) async {
  final json = await readImportSource(c);
  final Preset preset;
  if (json['prompts'] is List || json['prompt_order'] is List) {
    preset = parseSillyTavernPreset(json, '${json['name'] ?? 'Preset'}.json');
  } else {
    preset = Preset.fromJson({
      ...json,
      'id': generateId(),
      'name': json['name'] ?? 'Preset',
    });
  }
  await c.ref.read(presetListProvider.notifier).add(preset);
  return preset.id;
}

Future<Object?> _export(PluginCall c) async {
  final p = await _byId(c, c.arg(0));
  if (p == null) return null;
  return exportJson(c, presetExportJson(p), p.name);
}

Future<Object?> _setDefault(PluginCall c) async {
  final p = await _byId(c, c.arg(0));
  if (p == null) return null;
  c.ref.read(activePresetIdProvider.notifier).state = p.id;
  final prefs = await c.ref.read(sharedPreferencesProvider.future);
  await prefs.setString('activePresetId', p.id);
  return p.id;
}
