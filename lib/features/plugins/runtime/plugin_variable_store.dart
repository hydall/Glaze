import 'dart:convert';
import 'dart:io';

import '../../../core/db/repositories/chat_repo.dart';
import 'plugin_variable_paths.dart';

/// Size cap of a plugin's variables in one chat (or its messages), which
/// live in the session row.
const int kPluginVariableMaxBytes = 1024 * 1024;

/// Size cap of the `global` and `shared` files. Converted plugins keep
/// whole databases there, as the app they were written for allows.
const int kPluginGlobalVariableMaxBytes = 16 * 1024 * 1024;

/// Backing store for `glaze.variables.*`. Every plugin has its own
/// variables; `shared` is the one space plugins use together.
///
/// `chat` and `message` live in the session row, so they travel with the
/// chat (`message` is one map keyed by message id); `global` is a JSON file
/// in the plugin's data and `shared` one file for all plugins. All are
/// separate from the ExtBlocks variables.
class PluginVariableStore {
  PluginVariableStore({
    required this.chatRepo,
    required this.globalFile,
    required this.sharedFile,
  });

  static const chatKey = '__plugin_variables';
  static const messageKey = '__plugin_message_variables';

  static String chatKeyFor(String pluginId) => '$chatKey:$pluginId';
  static String messageKeyFor(String pluginId) => '$messageKey:$pluginId';

  final ChatRepo chatRepo;

  /// The `global` file of a plugin.
  final File Function(String pluginId) globalFile;
  final File sharedFile;
  Future<void> _globalLock = Future.value();

  File _fileFor(String pluginId, String scope) =>
      scope == 'shared' ? sharedFile : globalFile(pluginId);

  Future<Map<String, dynamic>> read(
    String pluginId,
    String scope,
    String? sessionId, {
    String? messageId,
  }) async {
    if (scope == 'global' || scope == 'shared') {
      return _readFile(_fileFor(pluginId, scope));
    }
    final session = await chatRepo.getById(_requireSession(sessionId));
    if (scope == 'message') {
      final all = decodeVariableRoot(
        session?.sessionVars[messageKeyFor(pluginId)],
      );
      final own = all[_requireMessage(messageId)];
      return own is Map ? Map<String, dynamic>.from(own) : {};
    }
    return decodeVariableRoot(session?.sessionVars[chatKeyFor(pluginId)]);
  }

  /// Applies [change] atomically and returns the new root.
  Future<Map<String, dynamic>> update(
    String pluginId,
    String scope,
    String? sessionId,
    void Function(Map<String, dynamic> root) change, {
    String? messageId,
  }) async {
    if (scope == 'global' || scope == 'shared') {
      final file = _fileFor(pluginId, scope);
      return _serialized(() async {
        final root = await _readFile(file);
        change(root);
        await _writeFile(
          file,
          _checked(root, max: kPluginGlobalVariableMaxBytes),
        );
        return root;
      });
    }
    final message = scope == 'message' ? _requireMessage(messageId) : null;
    var next = <String, dynamic>{};
    await chatRepo.updateSessionVarsJson(_requireSession(sessionId), (vars) {
      final key = message == null
          ? chatKeyFor(pluginId)
          : messageKeyFor(pluginId);
      final stored = decodeVariableRoot(vars[key] as String?);
      if (message == null) {
        next = stored;
        change(next);
      } else {
        final own = stored[message];
        next = own is Map ? Map<String, dynamic>.from(own) : {};
        change(next);
        if (next.isEmpty) {
          stored.remove(message);
        } else {
          stored[message] = next;
        }
      }
      final root = message == null ? next : stored;
      final encoded = _checked(root);
      if (root.isEmpty) {
        vars.remove(key);
      } else {
        vars[key] = encoded;
      }
      return vars;
    });
    return next;
  }

  /// Drops what [pluginId] kept in chats, for an uninstall or a package from
  /// another author taking over its id. Its `global` file goes with its
  /// data folder.
  Future<void> forgetPlugin(String pluginId) async {
    final keys = {chatKeyFor(pluginId), messageKeyFor(pluginId)};
    final ids = {
      for (final key in keys)
        ...await chatRepo.sessionIdsWithVarsContaining(jsonEncode(key)),
    };
    for (final id in ids) {
      await chatRepo.updateSessionVarsJson(
        id,
        (vars) => vars..removeWhere((k, _) => keys.contains(k)),
      );
    }
  }

  /// Drops the message-scope variables of deleted messages.
  Future<void> forgetMessages(String sessionId, Set<String> messageIds) async {
    if (messageIds.isEmpty) return;
    await chatRepo.updateSessionVarsJson(sessionId, (vars) {
      final keys = [
        for (final k in vars.keys)
          if (k.startsWith('$messageKey:')) k,
      ];
      for (final key in keys) {
        final stored = decodeVariableRoot(vars[key] as String?);
        final before = stored.length;
        stored.removeWhere((id, _) => messageIds.contains(id));
        if (stored.length == before) continue;
        if (stored.isEmpty) {
          vars.remove(key);
        } else {
          vars[key] = jsonEncode(stored);
        }
      }
      return vars;
    });
  }

  String _requireSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('No chat is open');
    }
    return sessionId;
  }

  String _requireMessage(String? messageId) {
    if (messageId == null || messageId.isEmpty) {
      throw ArgumentError('Message variables need a message id');
    }
    return messageId;
  }

  String _checked(
    Map<String, dynamic> root, {
    int max = kPluginVariableMaxBytes,
  }) {
    final encoded = jsonEncode(root);
    if (utf8.encode(encoded).length > max) {
      throw StateError('Plugin variables exceed $max bytes');
    }
    return encoded;
  }

  Future<Map<String, dynamic>> _readFile(File file) async {
    if (!await file.exists()) return {};
    return decodeVariableRoot(await file.readAsString());
  }

  Future<void> _writeFile(File file, String encoded) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  Future<T> _serialized<T>(Future<T> Function() op) {
    final run = _globalLock.then((_) => op());
    _globalLock = run.then((_) {}, onError: (_) {});
    return run;
  }
}
