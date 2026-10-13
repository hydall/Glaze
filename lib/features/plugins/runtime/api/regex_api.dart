import '../../../../core/models/preset.dart';
import '../../../../core/state/global_regex_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'library_io.dart';
import 'shapes.dart';

/// `glaze.regex.*`: the global regex scripts. Import takes Glaze scripts or
/// SillyTavern regex JSON (one script or a list).
Map<String, PluginMethod> regexApi() => {
  'regex.list': libraryRead(PluginPermission.regexRead, _list),
  'regex.get': libraryRead(PluginPermission.regexRead, _get),
  'regex.find': libraryRead(PluginPermission.regexRead, _find),
  'regex.create': libraryCreate(
    PluginPermission.regexCreate,
    _create,
    'plugins_consent_regex_create',
  ),
  'regex.update': libraryUpdate(
    PluginPermission.regexUpdate,
    _update,
    'plugins_consent_regex_update',
  ),
  'regex.remove': libraryDelete(
    PluginPermission.regexDelete,
    _remove,
    'plugins_consent_regex_remove',
  ),
  'regex.import': libraryCreate(
    PluginPermission.regexCreate,
    _import,
    'plugins_consent_regex_import',
  ),
  'regex.export': libraryRead(PluginPermission.regexRead, _export),
};

Future<List<PresetRegex>> _all(PluginCall c) =>
    c.ref.read(globalRegexProvider.future);

Future<PresetRegex?> _byId(PluginCall c, Object? id) async {
  final key = refId(id);
  return (await _all(c)).where((r) => r.id == key).firstOrNull;
}

Future<Object?> _list(PluginCall c) async => [
  for (final r in await _all(c)) r.toJson(),
];

Future<Object?> _get(PluginCall c) async =>
    (await _byId(c, c.arg(0)))?.toJson();

Future<Object?> _find(PluginCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  return [
    for (final r in await _all(c))
      if (nameMatches(r.name, query, match)) r.toJson(),
  ];
}

PresetRegex _parse(Map<String, dynamic> data, String id) {
  final st = data.containsKey('findRegex') || data.containsKey('scriptName');
  final json = st ? normalizeJsGlobalRegex(data) : data;
  final regex = PresetRegex.fromJson({...json, 'id': id});
  if (regex.name.isEmpty) {
    throw const PluginApiError('invalid_arguments', 'name is required');
  }
  return regex;
}

Future<Object?> _create(PluginCall c) async {
  final regex = _parse(c.mapArg(0), generateId());
  await c.ref.read(globalRegexProvider.notifier).addRegex(regex);
  return regex.id;
}

Future<Object?> _update(PluginCall c) async {
  final data = c.mapArg(0);
  final existing = await _byId(c, data['id']);
  if (existing == null) {
    throw PluginApiError('not_found', 'No regex ${data['id']}');
  }
  final regex = _parse({...existing.toJson(), ...data}, existing.id);
  await c.ref.read(globalRegexProvider.notifier).updateRegex(regex);
  return regex.id;
}

Future<Object?> _remove(PluginCall c) async {
  final r = await _byId(c, c.arg(0));
  if (r == null) return null;
  await c.ref.read(globalRegexProvider.notifier).removeRegex(r.id);
  return r.id;
}

Future<Object?> _import(PluginCall c) async {
  final source = c.arg(0);
  final items = source is List
      ? [
          for (final x in source)
            if (x is Map) Map<String, dynamic>.from(x),
        ]
      : [await readImportSource(c)];
  final ids = <String>[];
  for (final item in items) {
    final regex = _parse(item, generateId());
    await c.ref.read(globalRegexProvider.notifier).addRegex(regex);
    ids.add(regex.id);
  }
  return ids;
}

Future<Object?> _export(PluginCall c) async {
  final r = await _byId(c, c.arg(0));
  if (r == null) return null;
  return exportJson(c, r.toJson(), r.name);
}
