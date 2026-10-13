import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import '../plugin_variable_paths.dart';

/// `glaze.variables.*`: `list(scope)`, `get(name, scope)`, `set(name, value,
/// scope)`, `update(name, value, scope)` (shallow merge), `delete(name, scope)`.
/// Scope is `'chat'` (default), `'global'`, `{ scope: 'message', id }` or
/// `'shared'`. Each plugin has its own variables; `shared` is the space all
/// plugins read and write together.
Map<String, PluginMethod> variablesApi() => {
  'variables.list': const PluginMethod(_list, permission: _p),
  'variables.get': const PluginMethod(_get, permission: _p),
  'variables.set': const PluginMethod(_set, permission: _p),
  'variables.update': const PluginMethod(_update, permission: _p),
  'variables.delete': const PluginMethod(_delete, permission: _p),
};

const _p = PluginPermission.variables;

typedef _Scope = ({String scope, String? messageId});

_Scope _scope(PluginCall c, int index) {
  final raw = c.arg(index);
  if (raw is Map) {
    final scope = raw['scope'];
    if (scope == 'message') {
      final id = raw['id'] ?? c.messageId;
      return (scope: 'message', messageId: id?.toString());
    }
    return (scope: _named(scope), messageId: null);
  }
  if (raw == 'message') return (scope: 'message', messageId: c.messageId);
  return (scope: _named(raw), messageId: null);
}

String _named(Object? scope) =>
    scope == 'global' || scope == 'shared' ? scope as String : 'chat';

Future<Map<String, dynamic>> _read(PluginCall c, _Scope s) => c.host.variables
    .read(c.plugin.id, s.scope, c.host.sessionId, messageId: s.messageId);

Future<Object?> _list(PluginCall c) => _read(c, _scope(c, 0));

Future<Object?> _get(PluginCall c) async {
  final root = await _read(c, _scope(c, 1));
  return readVariablePath(root, splitVariablePath(c.arg(0)));
}

Future<void> _write(
  PluginCall c,
  _Scope s,
  void Function(Map<String, dynamic> root, List<String> path) change,
) async {
  final path = splitVariablePath(c.arg(0));
  final root = await c.host.variables.update(
    c.plugin.id,
    s.scope,
    c.host.sessionId,
    (root) => change(root, path),
    messageId: s.messageId,
  );
  if (s.scope == 'chat' || s.scope == 'global') {
    c.host.variablesChanged(c.plugin.id, s.scope, root);
  }
}

Future<Object?> _set(PluginCall c) async {
  final value = jsonClone(c.arg(1));
  await _write(c, _scope(c, 2), (root, path) {
    writeVariablePath(root, path, value);
  });
  return null;
}

Future<Object?> _update(PluginCall c) async {
  final value = jsonClone(c.arg(1));
  await _write(c, _scope(c, 2), (root, path) {
    writeVariablePath(
      root,
      path,
      mergeVariableValue(readVariablePath(root, path), value),
    );
  });
  return null;
}

Future<Object?> _delete(PluginCall c) async {
  var removed = false;
  await _write(c, _scope(c, 1), (root, path) {
    removed = removeVariablePath(root, path);
  });
  return removed;
}
