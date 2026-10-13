import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/plugins/plugin_hooks.dart';
import '../../chat/bridge/chat_bridge_controller.dart';
import '../models/plugin_manifest.dart';
import 'api/files_api.dart';
import 'plugin_bridge_service.dart';

/// A declared file handler of a running plugin.
class PluginFileHandlerEntry {
  const PluginFileHandlerEntry({
    required this.pluginId,
    required this.handler,
    required this.scripts,
  });

  final String pluginId;
  final PluginFileHandler handler;

  /// Sources of the handler's own scripts; empty when `main` registers it.
  final Future<List<Map<String, String>>> Function() scripts;
}

/// Result of a native-triggered plugin action.
class PluginActionResult {
  const PluginActionResult({required this.ok, this.reason, this.message});
  final bool ok;
  final String? reason;
  final String? message;
}

/// Result of a file handler run: the text for the model, or an error code
/// (`unsupported_format` lets the next handler try).
class PluginFileResult {
  const PluginFileResult({this.content, this.code, this.message});
  final String? content;
  final String? code;
  final String? message;
  bool get ok => content != null;
}

/// Drives the plugin frames inside one chat WebView: setup/teardown, event
/// fan-out, blocking hooks, actions and file handlers. Owns no Riverpod
/// state; the host widget feeds it.
class PluginChatRuntime implements PluginHookRunner {
  PluginChatRuntime({
    required this.bridge,
    required this.service,
    required this.chatId,
    required this.onCancelledSend,
    this.fileHandlers = const [],
    this.stageFile,
  }) {
    bridge.onPluginRequest = service.dispatch;
  }

  final ChatBridgeController bridge;
  final PluginBridgeService service;

  /// Current session id; read on every event.
  final String? Function() chatId;

  /// Shows the plugin's reason when `send:before` cancels.
  final void Function(String? message) onCancelledSend;

  /// Sorted by plugin id: the order handlers are tried in.
  final List<PluginFileHandlerEntry> fileHandlers;

  /// Writes an attached file where the plugin [pluginId] can read it and
  /// describes it as `{path, name, mimeType, size}`.
  final Future<Map<String, Object?>> Function(
    String pluginId,
    String name,
    Uint8List bytes,
  )?
  stageFile;

  bool _disposed = false;
  bool _ready = false;

  bool get isReady => _ready && !_disposed;

  /// (Re)creates every plugin frame from [payload]. Main scripts rerun.
  Future<void> setup(Map<String, Object?> payload) async {
    if (_disposed) return;
    final count = await bridge.callAsyncJs(
      'return window.glazePlugins ? window.glazePlugins.setup(payload) : -1;',
      arguments: {'payload': payload},
    );
    _ready = count is num && count >= 0;
    if (!_ready) debugPrint('[PluginRuntime] plugin host missing in WebView');
  }

  Future<void> teardown() async {
    _ready = false;
    await bridge.callAsyncJs(
      'if (window.glazePlugins) window.glazePlugins.teardown(); return true;',
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(bridge.onPluginRequest, service.dispatch)) {
      bridge.onPluginRequest = null;
    }
    unawaited(teardown().catchError((Object _) {}));
  }

  void _fire(String body, Map<String, dynamic> arguments) {
    if (!isReady) return;
    unawaited(
      bridge
          .callAsyncJs('$body return true;', arguments: arguments)
          .catchError((Object _) => null),
    );
  }

  void dispatchEvent(String type, Map<String, Object?> payload) =>
      _fire('window.glazePlugins.dispatchEvent(type, payload);', {
        'type': type,
        'payload': {...payload, 'at': DateTime.now().toUtc().toIso8601String()},
      });

  void pushVars(String pluginId, String scope, Map<String, dynamic> root) =>
      _fire('window.glazePlugins.pushVars(pluginId, scope, value);', {
        'pluginId': pluginId,
        'scope': scope,
        'value': root,
      });

  /// Message order and roles for message panels and message actions.
  void setMessages(
    List<Map<String, Object?>> messages, {
    required bool busy,
    required String? chatId,
  }) => _fire('window.glazePlugins.setMessages(list, busy, chatId);', {
    'list': messages,
    'busy': busy,
    'chatId': chatId,
  });

  Future<void> updateLocalization(List<Map<String, Object?>> entries) async {
    if (!isReady) return;
    await bridge.callAsyncJs(
      'window.glazePlugins.updateLocalization(list); return true;',
      arguments: {'list': entries},
    );
  }

  Future<Map<String, dynamic>?> _intercept(
    String type,
    Map<String, Object?> payload,
  ) async {
    if (!isReady) return null;
    try {
      final result = await bridge.callAsyncJs(
        'return await window.glazePlugins.intercept(type, payload);',
        arguments: {
          'type': type,
          'payload': {
            ...payload,
            'chatId': chatId(),
            'at': DateTime.now().toUtc().toIso8601String(),
          },
        },
        timeout: const Duration(seconds: 130),
      );
      return result is Map ? Map<String, dynamic>.from(result) : null;
    } catch (e) {
      debugPrint('[PluginRuntime] $type failed: $e');
      return null;
    }
  }

  @override
  Future<PluginSendHookResult> beforeSend(
    String text, {
    required String source,
  }) async {
    final result = await _intercept('send:before', {
      'text': text,
      'source': source,
    });
    if (result == null || result['text'] is! String) {
      return PluginSendHookResult(text: text);
    }
    final cancelled = result['cancelled'] == true;
    final message = result['message'] as String?;
    if (cancelled) onCancelledSend(message);
    return PluginSendHookResult(
      text: result['text'] as String,
      cancelled: cancelled,
      cancelledBy: result['cancelledBy'] as String?,
      message: message,
    );
  }

  @override
  Future<String> prepareGeneration(
    String text, {
    required String source,
    required String generationId,
  }) async {
    final result = await _intercept('generation:prepare', {
      'text': text,
      'source': source,
      'generationId': generationId,
    });
    final next = result?['text'];
    return next is String ? next : text;
  }

  @override
  Future<String> finishGeneration(
    String text, {
    required String source,
    required String generationId,
  }) async {
    final result = await _intercept('generation:success', {
      'text': text,
      'source': source,
      'generationId': generationId,
    });
    final next = result?['text'];
    return next is String && next.trim().isNotEmpty ? next : text;
  }

  @override
  Set<String> get fileExtensions => {
    for (final entry in fileHandlers) ...entry.handler.extensions,
  };

  @override
  Future<PluginFileExtraction> extractFile(String name, Uint8List bytes) async {
    final stage = stageFile;
    final mimeType = pluginMimeType(name);
    String? error;
    for (final entry in fileHandlers) {
      if (stage == null || !entry.handler.matches(name, mimeType)) continue;
      final file = await stage(entry.pluginId, name, bytes);
      final result = await runFileHandler(
        entry.pluginId,
        entry.handler.id,
        file,
        await entry.scripts(),
      );
      if (result.ok) return PluginFileExtraction(content: result.content);
      if (result.code == 'unsupported_format') continue;
      error = result.message ?? result.code;
      break;
    }
    return PluginFileExtraction(handled: error != null, error: error);
  }

  @override
  void notify(String type, Map<String, Object?> payload) => dispatchEvent(
    type,
    {...payload, 'chatId': payload['chatId'] ?? chatId()},
  );

  /// Runs an `action:composer:` / `action:tools:` / `action:message:` handler.
  Future<PluginActionResult> runAction(
    String pluginId,
    String event, {
    Map<String, Object?>? args,
  }) async {
    if (!isReady) {
      return const PluginActionResult(ok: false, reason: 'runtime-not-ready');
    }
    try {
      final result = await bridge.callAsyncJs(
        'return await window.glazePlugins.runAction(pluginId, event, args);',
        arguments: {'pluginId': pluginId, 'event': event, 'args': args},
        timeout: const Duration(minutes: 11),
      );
      if (result is! Map) {
        return const PluginActionResult(ok: false, reason: 'runtime-not-ready');
      }
      return PluginActionResult(
        ok: result['ok'] == true,
        reason: result['reason'] as String?,
        message: result['message'] as String?,
      );
    } catch (e) {
      return PluginActionResult(
        ok: false,
        reason: 'handler-error',
        message: e.toString(),
      );
    }
  }

  /// Runs one file handler on [file] (`{path, name, mimeType, size}`, the
  /// path readable through the plugin's files).
  Future<PluginFileResult> runFileHandler(
    String pluginId,
    String handlerId,
    Map<String, Object?> file,
    List<Map<String, String>> scripts,
  ) async {
    if (!isReady) {
      return const PluginFileResult(code: 'runtime-not-ready');
    }
    try {
      final result = await bridge.callAsyncJs(
        'return await window.glazePlugins.runFileHandler(pluginId, handlerId, file, scripts);',
        arguments: {
          'pluginId': pluginId,
          'handlerId': handlerId,
          'file': file,
          'scripts': scripts,
        },
        timeout: const Duration(minutes: 11),
      );
      if (result is! Map) return const PluginFileResult(code: 'failed');
      if (result['ok'] == true && result['content'] is String) {
        return PluginFileResult(content: result['content'] as String);
      }
      final error = result['error'];
      return PluginFileResult(
        code: error is Map ? '${error['code']}' : 'failed',
        message: error is Map ? error['message']?.toString() : null,
      );
    } catch (e) {
      return PluginFileResult(code: 'failed', message: '$e');
    }
  }
}
