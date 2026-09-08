import 'dart:convert';

import '../js_bridge_context.dart';

class VariablesHandler {
  static const _chatVarsKey = '__glaze_variables';
  static const _characterVarsKey = 'glaze_variables';
  static const _maxJsonBytes = 64 * 1024;

  const VariablesHandler();

  Future<dynamic> getVariables(JsBridgeContext bridge) {
    final scope = _scope(bridge.params);
    return _getVariables(bridge, scope);
  }

  Future<Map<String, dynamic>> setVariables(JsBridgeContext bridge) {
    final scope = _scope(bridge.params);
    return _setVariables(bridge, scope);
  }

  Future<Map<String, dynamic>> deleteVariable(JsBridgeContext bridge) {
    final scope = _scope(bridge.params);
    return _deleteVariable(bridge, scope);
  }

  Future<dynamic> _getVariables(JsBridgeContext bridge, String scope) async {
    final root = await _readScope(bridge, scope);
    final path = _path(bridge.params['path']);
    return _cloneJson(path.isEmpty ? root : _getAtPath(root, path));
  }

  Future<Map<String, dynamic>> _setVariables(
    JsBridgeContext bridge,
    String scope,
  ) {
    final path = _path(bridge.params['path']);
    final hasValue = bridge.params.containsKey('value');
    final value = hasValue ? bridge.params['value'] : bridge.params['values'];
    _validateJsonValue(value);

    return _updateScope(bridge, scope, (root) {
      if (path.isEmpty) {
        final values = asBridgeMap(value);
        if (values.isEmpty && value is! Map) {
          throw ArgumentError('setVariables without path requires an object');
        }
        root.addAll(Map<String, dynamic>.from(values));
      } else {
        _setAtPath(root, path, value);
      }
      _validateJsonValue(root);
      return root;
    });
  }

  Future<Map<String, dynamic>> _deleteVariable(
    JsBridgeContext bridge,
    String scope,
  ) {
    final path = _path(bridge.params['path']);
    if (path.isEmpty) throw ArgumentError('deleteVariable path is required');

    return _updateScope(bridge, scope, (root) {
      _deleteAtPath(root, path);
      return root;
    });
  }

  Future<Map<String, dynamic>> _readScope(
    JsBridgeContext bridge,
    String scope,
  ) async {
    switch (scope) {
      case 'chat':
        final repo = bridge.chatRepo;
        final session = await repo.getById(bridge.sessionId());
        if (session == null) {
          throw StateError(
            'Chat session "${bridge.sessionId()}" was not found',
          );
        }
        return _decodeChatVars(session.sessionVars);
      case 'character':
        final repo = bridge.characterRepo;
        final character = await repo.getById(bridge.characterId());
        if (character == null) {
          throw StateError('Character "${bridge.characterId()}" was not found');
        }
        return _decodeCharacterVars(character.extensions);
      case 'global':
        final repo = bridge.globalVariablesRepo;
        return await repo.read();
      case 'message':
        return _readMessageScope(bridge);
      default:
        throw ArgumentError('Unsupported variable scope "$scope"');
    }
  }

  Future<Map<String, dynamic>> _updateScope(
    JsBridgeContext bridge,
    String scope,
    Map<String, dynamic> Function(Map<String, dynamic> root) update,
  ) async {
    switch (scope) {
      case 'chat':
        final repo = bridge.chatRepo;
        Map<String, dynamic> nextRoot = const {};
        await repo.updateSessionVarsJson(bridge.sessionId(), (vars) {
          nextRoot = update(_decodeChatVars(vars));
          if (nextRoot.isEmpty) {
            vars.remove(_chatVarsKey);
          } else {
            vars[_chatVarsKey] = jsonEncode(nextRoot);
          }
          return vars;
        });
        return Map<String, dynamic>.from(nextRoot);
      case 'character':
        final repo = bridge.characterRepo;
        Map<String, dynamic> nextRoot = const {};
        await repo.updateExtensionsJson(bridge.characterId(), (extensions) {
          nextRoot = update(_decodeCharacterVars(extensions));
          if (nextRoot.isEmpty) {
            extensions.remove(_characterVarsKey);
          } else {
            extensions[_characterVarsKey] = nextRoot;
          }
          return extensions;
        });
        return Map<String, dynamic>.from(nextRoot);
      case 'global':
        final repo = bridge.globalVariablesRepo;
        return await repo.update(update);
      case 'message':
        return _updateMessageScope(bridge, update);
      default:
        throw ArgumentError('Unsupported variable scope "$scope"');
    }
  }

  Map<String, dynamic> _readMessageScope(JsBridgeContext bridge) {
    final accessor = bridge.messageVariables;
    return accessor().read(bridge.sessionId(), bridge.messageId());
  }

  Map<String, dynamic> _updateMessageScope(
    JsBridgeContext bridge,
    Map<String, dynamic> Function(Map<String, dynamic> root) update,
  ) {
    final accessor = bridge.messageVariables;
    return accessor().update(bridge.sessionId(), bridge.messageId(), update);
  }

  String _scope(Map<String, dynamic> params) {
    final scope = (params['scope'] as String? ?? 'chat').trim().toLowerCase();
    return scope.isEmpty ? 'chat' : scope;
  }

  List<String> _path(Object? value) {
    if (value == null) return const [];
    if (value is! String) throw ArgumentError('Variable path must be a string');
    final trimmed = value.trim();
    if (trimmed.isEmpty) return const [];
    final parts = trimmed.split('.');
    if (parts.any((p) => p.isEmpty)) {
      throw ArgumentError('Variable path contains an empty segment');
    }
    return parts;
  }

  dynamic _getAtPath(Map<String, dynamic> root, List<String> path) {
    dynamic current = root;
    for (final part in path) {
      if (current is! Map || !current.containsKey(part)) return null;
      current = current[part];
    }
    return current;
  }

  void _setAtPath(Map<String, dynamic> root, List<String> path, Object? value) {
    var current = root;
    for (final part in path.take(path.length - 1)) {
      final existing = current[part];
      final child = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      current[part] = child;
      current = child;
    }
    current[path.last] = value;
  }

  void _deleteAtPath(Map<String, dynamic> root, List<String> path) {
    dynamic current = root;
    for (final part in path.take(path.length - 1)) {
      if (current is! Map) return;
      current = current[part];
    }
    if (current is Map) current.remove(path.last);
  }

  Map<String, dynamic> _decodeChatVars(Map<String, dynamic> vars) {
    final raw = vars[_chatVarsKey];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _decodeCharacterVars(Map<String, dynamic> extensions) {
    final raw = extensions[_characterVarsKey];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  dynamic _cloneJson(Object? value) {
    if (value == null) return null;
    return jsonDecode(jsonEncode(value));
  }

  void _validateJsonValue(Object? value) {
    void visit(Object? current) {
      if (current == null || current is bool || current is String) return;
      if (current is num) {
        if (!current.isFinite) {
          throw ArgumentError('JSON numbers must be finite');
        }
        return;
      }
      if (current is List) {
        for (final item in current) {
          visit(item);
        }
        return;
      }
      if (current is Map) {
        for (final entry in current.entries) {
          if (entry.key is! String) {
            throw ArgumentError('JSON object keys must be strings');
          }
          visit(entry.value);
        }
        return;
      }
      throw ArgumentError('Value is not JSON-compatible');
    }

    visit(value);
    if (utf8.encode(jsonEncode(value)).length > _maxJsonBytes) {
      throw ArgumentError('Variable payload exceeds $_maxJsonBytes bytes');
    }
  }
}
