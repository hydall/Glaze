import 'dart:convert';

/// Dotted-path helpers for `glaze.variables.*` (`'status.hp'`).
List<String> splitVariablePath(Object? name) {
  if (name is! String) throw ArgumentError('Variable name must be a string');
  final parts = name.split('.').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) throw ArgumentError('Variable name is required');
  return parts;
}

Object? readVariablePath(Map<String, dynamic> root, List<String> path) {
  Object? node = root;
  for (final part in path) {
    if (node is Map && node.containsKey(part)) {
      node = node[part];
    } else {
      return null;
    }
  }
  return node;
}

void writeVariablePath(
  Map<String, dynamic> root,
  List<String> path,
  Object? value,
) {
  var node = root;
  for (final part in path.take(path.length - 1)) {
    final next = node[part];
    if (next is Map<String, dynamic>) {
      node = next;
    } else {
      final created = <String, dynamic>{};
      node[part] = created;
      node = created;
    }
  }
  node[path.last] = value;
}

bool removeVariablePath(Map<String, dynamic> root, List<String> path) {
  Object? node = root;
  for (final part in path.take(path.length - 1)) {
    if (node is! Map) return false;
    node = node[part];
  }
  if (node is! Map || !node.containsKey(path.last)) return false;
  node.remove(path.last);
  return true;
}

/// `update`: shallow-merges plain objects, otherwise behaves like `set`.
Object? mergeVariableValue(Object? previous, Object? next) {
  if (previous is Map && next is Map) {
    return <String, dynamic>{
      ...Map<String, dynamic>.from(previous),
      ...Map<String, dynamic>.from(next),
    };
  }
  return next;
}

/// Deep copy through JSON, which also rejects values that cannot be stored.
Object? jsonClone(Object? value) => jsonDecode(jsonEncode(value));

Map<String, dynamic> decodeVariableRoot(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  } catch (_) {
    return {};
  }
}
