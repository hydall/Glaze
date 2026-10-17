import '../../../../core/models/persona.dart';
import '../../../../core/state/active_selection_provider.dart';
import '../../../../core/state/shared_prefs_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../personas/persona_list_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'library_io.dart';
import 'shapes.dart';

/// `glaze.personas.*`.
Map<String, PluginMethod> personasApi() => {
  'personas.list': libraryRead(PluginPermission.personasRead, _list),
  'personas.get': libraryRead(PluginPermission.personasRead, _get),
  'personas.find': libraryRead(PluginPermission.personasRead, _find),
  'personas.current': libraryRead(PluginPermission.personasRead, _current),
  'personas.create': libraryCreate(
    PluginPermission.personasCreate,
    _create,
    'plugins_consent_persona_create',
  ),
  'personas.update': libraryUpdate(
    PluginPermission.personasUpdate,
    _update,
    'plugins_consent_persona_update',
  ),
  'personas.remove': libraryDelete(
    PluginPermission.personasDelete,
    _remove,
    'plugins_consent_persona_remove',
  ),
  'personas.setDefault': libraryUpdate(
    PluginPermission.personasUpdate,
    _setDefault,
    'plugins_consent_persona_default',
  ),
};

Future<List<Persona>> _all(PluginCall c) =>
    c.ref.read(personaListProvider.future);

String? get _none => null;

Persona? _current0(PluginCall c) => c.ref.read(
  effectivePersonaForChatProvider((
    charId: c.host.charId,
    sessionId: c.host.sessionId,
  )),
);

Map<String, Object?> _json(PluginCall c, Persona p) =>
    personaJson(p, active: p.id == c.ref.read(activePersonaIdProvider));

Future<Persona?> _byId(PluginCall c, Object? id) async {
  final key = (id is Map ? id['id'] : id)?.toString() ?? _none;
  return (await _all(c)).where((p) => p.id == key).firstOrNull;
}

Future<Object?> _list(PluginCall c) async => [
  for (final p in await _all(c)) {'id': p.id, 'name': personaName(p)},
];

Future<Object?> _get(PluginCall c) async {
  final p = await _byId(c, c.arg(0));
  return p == null ? null : _json(c, p);
}

Future<Object?> _current(PluginCall c) async {
  final p = _current0(c);
  return p == null ? null : _json(c, p);
}

Future<Object?> _find(PluginCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  return [
    for (final p in await _all(c))
      if (nameMatches(p.name, query, match) ||
          nameMatches(personaName(p), query, match))
        _json(c, p),
  ];
}

Future<Object?> _create(PluginCall c) async {
  final data = c.mapArg(0);
  final name = data['name'];
  if (name is! String || name.trim().isEmpty) {
    throw const PluginApiError('invalid_arguments', 'name is required');
  }
  final p = applyPersonaJson(
    Persona(
      id: generateId(),
      name: name,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ),
    data,
  );
  await c.ref.read(personaListProvider.notifier).add(p);
  return p.id;
}

Future<Object?> _update(PluginCall c) async {
  final data = c.mapArg(0);
  final p = await _byId(c, data['id']);
  if (p == null) throw PluginApiError('not_found', 'No persona ${data['id']}');
  await c.ref
      .read(personaListProvider.notifier)
      .updatePersona(applyPersonaJson(p, data));
  return p.id;
}

Future<Object?> _remove(PluginCall c) async {
  final p = await _byId(c, c.arg(0));
  if (p == null) return null;
  await c.ref.read(personaListProvider.notifier).remove(p.id);
  return p.id;
}

Future<Object?> _setDefault(PluginCall c) async {
  final p = await _byId(c, c.arg(0));
  if (p == null) return null;
  c.ref.read(activePersonaIdProvider.notifier).state = p.id;
  final prefs = await c.ref.read(sharedPreferencesProvider.future);
  await prefs.setString('activePersonaId', p.id);
  return p.id;
}
