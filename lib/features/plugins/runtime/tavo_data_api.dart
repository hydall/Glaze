import '../../../core/models/chat_message.dart';
import 'tavo_call.dart';
import 'tavo_host.dart';
import 'tavo_variable_paths.dart';

/// `tavo.variable.*`, `tavo.message.*` (read side), `tavo.chat.current`,
/// `tavo.character.*`, `tavo.persona.*`.
Map<String, TavoMethod> tavoDataMethods() => {
  'variable.list': const TavoMethod(_variableList, permission: 'variable'),
  'variable.get': const TavoMethod(_variableGet, permission: 'variable'),
  'variable.set': const TavoMethod(_variableSet, permission: 'variable'),
  'variable.update': const TavoMethod(_variableUpdate, permission: 'variable'),
  'variable.unset': const TavoMethod(_variableUnset, permission: 'variable'),
  'message.find': const TavoMethod(_messageFind, permission: 'message'),
  'message.get': const TavoMethod(_messageGet, permission: 'message'),
  'message.count': const TavoMethod(_messageCount, permission: 'message'),
  'message.current': const TavoMethod(_messageCurrent, permission: 'message'),
  'chat.current': const TavoMethod(_chatCurrent),
  'character.all': const TavoMethod(_characterAll),
  'character.get': const TavoMethod(_characterGet),
  'character.find': const TavoMethod(_characterFind),
  'character.current': const TavoMethod(_characterCurrent),
  'persona.all': const TavoMethod(_personaAll),
  'persona.get': const TavoMethod(_personaGet),
  'persona.find': const TavoMethod(_personaFind),
  'persona.current': const TavoMethod(_personaCurrent),
};

/* ---------- variables ---------- */

String _scope(TavoCall c) => c.named('scope') == 'global' ? 'global' : 'chat';

Future<Object?> _variableList(TavoCall c) =>
    c.host.variables.read(_scope(c), c.host.sessionId);

Future<Object?> _variableGet(TavoCall c) async {
  final root = await c.host.variables.read(_scope(c), c.host.sessionId);
  return readVariablePath(root, splitVariablePath(c.named('name')));
}

Future<Object?> _write(
  TavoCall c,
  void Function(Map<String, dynamic> root, List<String> path) change,
) async {
  final scope = _scope(c);
  final path = splitVariablePath(c.named('name'));
  final root = await c.host.variables.update(
    scope,
    c.host.sessionId,
    (root) => change(root, path),
  );
  c.host.variablesChanged(scope, root);
  return root;
}

Future<Object?> _variableSet(TavoCall c) async {
  final value = jsonClone(c.named('value'));
  await _write(c, (root, path) => writeVariablePath(root, path, value));
  return null;
}

Future<Object?> _variableUpdate(TavoCall c) async {
  final value = jsonClone(c.named('value'));
  await _write(c, (root, path) {
    final merged = mergeVariableValue(readVariablePath(root, path), value);
    writeVariablePath(root, path, merged);
  });
  return null;
}

Future<Object?> _variableUnset(TavoCall c) async {
  var removed = false;
  await _write(c, (root, path) => removed = removeVariablePath(root, path));
  return removed;
}

/* ---------- messages ---------- */

List<ChatMessage> _messages(TavoCall c) =>
    c.host.currentSession()?.messages ?? const [];

int? _int(Object? v) => v is num ? v.toInt() : null;

Future<Object?> _messageFind(TavoCall c) async {
  final all = _messages(c);
  final range = c.arg(0);
  var start = 0;
  var end = all.length - 1;
  int norm(int i) => i < 0 ? all.length + i : i;
  if (range is num) {
    start = end = norm(range.toInt());
  } else if (range is List && range.isNotEmpty) {
    start = norm(_int(range[0]) ?? 0);
    if (range.length > 1) end = norm(_int(range[1]) ?? end);
  }
  start = start.clamp(0, all.length);
  end = end.clamp(-1, all.length - 1);
  final filter = c.mapArg(1);
  final role = filter['role'];
  final hidden = filter['hidden'];
  return [
    for (var i = start; i <= end; i++)
      if ((role == null || all[i].role == role) &&
          (hidden is! bool || all[i].isHidden == hidden))
        tavoMessageJson(all[i], index: i, charId: c.host.charId),
  ];
}

Future<Object?> _messageGet(TavoCall c) async {
  final all = _messages(c);
  final key = c.arg(0);
  var index = -1;
  if (key is Map && key['index'] is num) {
    final i = (key['index'] as num).toInt();
    index = i < 0 ? all.length + i : i;
  } else if (key != null) {
    final id = key is Map ? key['id'] : key;
    index = all.indexWhere((m) => m.id == id?.toString());
  }
  if (index < 0 || index >= all.length) return null;
  return tavoMessageJson(all[index], index: index, charId: c.host.charId);
}

Future<Object?> _messageCount(TavoCall c) async => _messages(c).length;

/// Only `/messages` fragments have a host message; Glaze has none yet.
Future<Object?> _messageCurrent(TavoCall c) async => null;

/* ---------- chat / character / persona ---------- */

Future<Object?> _chatCurrent(TavoCall c) async => tavoCurrentChatJson(c.host);

/// Tavo's chat object for the open chat; null when none is open.
Map<String, Object?>? tavoCurrentChatJson(TavoHost host) {
  final session = host.currentSession();
  if (session == null) return null;
  final character = host.currentCharacter();
  final persona = host.currentPersona();
  return {
    'id': session.id,
    'name': session.sessionVars['sessionName'] ?? character?.name ?? '',
    'characters': [
      if (character != null)
        {'id': character.id, 'name': tavoCharacterJson(character)['name']},
    ],
    'persona': persona == null
        ? null
        : {
            'id': persona.id,
            'name': tavoPersonaJson(persona, active: true)['name'],
          },
  };
}

bool _matches(String name, String query, Object? match) => switch (match) {
  'prefix' => name.startsWith(query),
  'suffix' => name.endsWith(query),
  'contains' => name.contains(query),
  _ => name == query,
};

Future<Object?> _characterAll(TavoCall c) async => [
  for (final ch in await c.host.characters())
    {'id': ch.id, 'name': tavoCharacterJson(ch)['name']},
];

Future<Object?> _characterGet(TavoCall c) async {
  final id = c.arg(0)?.toString();
  final current = c.host.currentCharacter();
  if (current != null && current.id == id) return tavoCharacterJson(current);
  for (final ch in await c.host.characters()) {
    if (ch.id == id) return tavoCharacterJson(ch);
  }
  return null;
}

Future<Object?> _characterFind(TavoCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  return [
    for (final ch in await c.host.characters())
      if (_matches(tavoCharacterJson(ch)['name'] as String, query, match))
        tavoCharacterJson(ch),
  ];
}

Future<Object?> _characterCurrent(TavoCall c) async {
  final ch = c.host.currentCharacter();
  return ch == null ? null : tavoCharacterJson(ch);
}

Future<Object?> _personaAll(TavoCall c) async {
  final activeId = c.host.currentPersona()?.id;
  return [
    for (final p in await c.host.personas())
      {
        'id': p.id,
        'name': tavoPersonaJson(p, active: p.id == activeId)['name'],
      },
  ];
}

Future<Object?> _personaGet(TavoCall c) async {
  final id = c.arg(0)?.toString();
  final activeId = c.host.currentPersona()?.id;
  for (final p in await c.host.personas()) {
    if (p.id == id) return tavoPersonaJson(p, active: p.id == activeId);
  }
  return null;
}

Future<Object?> _personaFind(TavoCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  final activeId = c.host.currentPersona()?.id;
  return [
    for (final p in await c.host.personas())
      if (_matches(
        tavoPersonaJson(p, active: false)['name'] as String,
        query,
        match,
      ))
        tavoPersonaJson(p, active: p.id == activeId),
  ];
}

Future<Object?> _personaCurrent(TavoCall c) async {
  final p = c.host.currentPersona();
  return p == null ? null : tavoPersonaJson(p, active: true);
}
