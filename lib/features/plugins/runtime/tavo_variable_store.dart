import 'dart:convert';
import 'dart:io';

import '../../../core/db/repositories/chat_repo.dart';
import 'tavo_variable_paths.dart';

/// Size cap per scope. Plugins are told to keep large blobs in files.
const int kTavoVariableMaxBytes = 1024 * 1024;

/// Backing store for `tavo.variable.*`.
///
/// `chat` lives in the session row (`sessionVars['__tavo_variables']`), so it
/// travels with the chat; `global` is one JSON file shared by all plugins.
/// Both are separate from the `glaze.*` SDK's variables.
class TavoVariableStore {
  TavoVariableStore({required this.chatRepo, required this.globalFile});

  static const chatKey = '__tavo_variables';

  final ChatRepo chatRepo;
  final File globalFile;
  Future<void> _globalLock = Future.value();

  Future<Map<String, dynamic>> read(String scope, String? sessionId) async {
    if (scope == 'global') return _readGlobal();
    final session = await chatRepo.getById(_requireSession(sessionId));
    return decodeVariableRoot(session?.sessionVars[chatKey]);
  }

  /// Applies [change] atomically and returns the new root.
  Future<Map<String, dynamic>> update(
    String scope,
    String? sessionId,
    void Function(Map<String, dynamic> root) change,
  ) async {
    if (scope == 'global') {
      return _serialized(() async {
        final root = await _readGlobal();
        change(root);
        await _writeGlobal(_checked(root));
        return root;
      });
    }
    var next = <String, dynamic>{};
    await chatRepo.updateSessionVarsJson(_requireSession(sessionId), (vars) {
      next = decodeVariableRoot(vars[chatKey] as String?);
      change(next);
      final encoded = _checked(next);
      if (next.isEmpty) {
        vars.remove(chatKey);
      } else {
        vars[chatKey] = encoded;
      }
      return vars;
    });
    return next;
  }

  String _requireSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('No chat is open');
    }
    return sessionId;
  }

  String _checked(Map<String, dynamic> root) {
    final encoded = jsonEncode(root);
    if (utf8.encode(encoded).length > kTavoVariableMaxBytes) {
      throw StateError('Plugin variables exceed $kTavoVariableMaxBytes bytes');
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
