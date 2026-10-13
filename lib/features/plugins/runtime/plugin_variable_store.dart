import 'dart:convert';
import 'dart:io';

import '../../../core/db/repositories/chat_repo.dart';
import 'plugin_variable_paths.dart';

/// Size cap per scope. Plugins are told to keep large blobs in files.
const int kPluginVariableMaxBytes = 1024 * 1024;

/// Backing store for `glaze.variables.*`.
///
/// `chat` and `message` live in the session row, so they travel with the
/// chat (`message` is one map keyed by message id); `global` is one JSON file
/// shared by all plugins. All are separate from the ExtBlocks variables.
class PluginVariableStore {
  PluginVariableStore({required this.chatRepo, required this.globalFile});

  static const chatKey = '__plugin_variables';
  static const messageKey = '__plugin_message_variables';

  final ChatRepo chatRepo;
  final File globalFile;
  Future<void> _globalLock = Future.value();

  Future<Map<String, dynamic>> read(
    String scope,
    String? sessionId, {
    String? messageId,
  }) async {
    if (scope == 'global') return _readGlobal();
    final session = await chatRepo.getById(_requireSession(sessionId));
    if (scope == 'message') {
      final all = decodeVariableRoot(session?.sessionVars[messageKey]);
      final own = all[_requireMessage(messageId)];
      return own is Map ? Map<String, dynamic>.from(own) : {};
    }
    return decodeVariableRoot(session?.sessionVars[chatKey]);
  }

  /// Applies [change] atomically and returns the new root.
  Future<Map<String, dynamic>> update(
    String scope,
    String? sessionId,
    void Function(Map<String, dynamic> root) change, {
    String? messageId,
  }) async {
    if (scope == 'global') {
      return _serialized(() async {
        final root = await _readGlobal();
        change(root);
        await _writeGlobal(_checked(root));
        return root;
      });
    }
    final message = scope == 'message' ? _requireMessage(messageId) : null;
    var next = <String, dynamic>{};
    await chatRepo.updateSessionVarsJson(_requireSession(sessionId), (vars) {
      final key = message == null ? chatKey : messageKey;
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

  /// Drops the message-scope variables of deleted messages.
  Future<void> forgetMessages(String sessionId, Set<String> messageIds) async {
    if (messageIds.isEmpty) return;
    await chatRepo.updateSessionVarsJson(sessionId, (vars) {
      final stored = decodeVariableRoot(vars[messageKey] as String?);
      final before = stored.length;
      stored.removeWhere((id, _) => messageIds.contains(id));
      if (stored.length == before) return vars;
      if (stored.isEmpty) {
        vars.remove(messageKey);
      } else {
        vars[messageKey] = jsonEncode(stored);
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

  String _checked(Map<String, dynamic> root) {
    final encoded = jsonEncode(root);
    if (utf8.encode(encoded).length > kPluginVariableMaxBytes) {
      throw StateError(
        'Plugin variables exceed $kPluginVariableMaxBytes bytes',
      );
    }
    return encoded;
  }

  Future<Map<String, dynamic>> _readGlobal() async {
    if (!await globalFile.exists()) return {};
    return decodeVariableRoot(await globalFile.readAsString());
  }

  Future<void> _writeGlobal(String encoded) async {
    await globalFile.parent.create(recursive: true);
    final tmp = File('${globalFile.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(globalFile.path);
  }

  Future<T> _serialized<T>(Future<T> Function() op) {
    final run = _globalLock.then((_) => op());
    _globalLock = run.then((_) {}, onError: (_) {});
    return run;
  }
}
