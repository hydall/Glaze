import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/plugins/plugin_hooks.dart';
import '../../chat/bridge/chat_bridge_controller.dart';
import '../models/plugin_manifest.dart';
import '../widgets/plugin_layer.dart';
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

/// Runs a JS function body in one of the pages.
typedef _PageCall =
    Future<Object?> Function(
      String functionBody, {
      Map<String, dynamic> arguments,
      Duration timeout,
    });

/// Result of a native-triggered plugin action.
class PluginActionResult {
  const PluginActionResult({
    required this.ok,
    this.reason,
    this.message,
    this.value,
  });
  final bool ok;
  final String? reason;
  final String? message;

  /// What the handler returned, when it survived JSON.
  final Object? value;
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

/// Drives the plugin frames inside one chat WebView, and the plugin layer
/// over it when there is one: setup/teardown, event fan-out, blocking hooks,
/// actions and file handlers. Owns no Riverpod state; the host widget feeds
/// it.
class PluginChatRuntime implements PluginHookRunner {
  PluginChatRuntime({
    required this.bridge,
    required this.service,
    required this.chatId,
    required this.onCancelledSend,
    this.layer,
    this.fileHandlers = const [],
    this.stageFile,
  }) {
    bridge.onPluginRequest = service.dispatch;
    final layer = this.layer;
    if (layer == null) return;
    layer.onPluginRequest = service.dispatch;
    // What crosses between the two pages.
    bridge.onPluginEmit = (emit) => _relayEmit(layer.callAsyncJs, emit);
    layer.onPluginEmit = (emit) => _relayEmit(bridge.callAsyncJs, emit);
    bridge.onPluginInsets = (insets) {
      if (_disposed) return;
      unawaited(
        layer
            .callAsyncJs(
              'window.glazePlugins.setInsets(insets); return true;',
              arguments: {'insets': insets},
            )
            .catchError((Object _) => null),
      );
    };
  }

  final ChatBridgeController bridge;
  final PluginBridgeService service;

  /// The plugin layer holding the chat panels; null when they are in the
  /// chat page.
  final PluginLayerController? layer;

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

  /// Plugin ids in setup order.
  List<String> _order = const [];

  /// Plugins whose main script runs in the plugin layer: it shares one page
  /// with their chat panels (`onePage`), which are there.
  Set<String> _mainsInLayer = const {};

  /// The page running [pluginId]'s main script.
  _PageCall _mainPage(String pluginId) {
    final layer = this.layer;
    return layer != null && _mainsInLayer.contains(pluginId)
        ? layer.callAsyncJs
        : bridge.callAsyncJs;
  }

  bool get isReady => _ready && !_disposed;

  /// (Re)creates every plugin frame from [payload]. Main scripts rerun.
  Future<void> setup(Map<String, Object?> payload) async {
    if (_disposed) return;
    final entries = [
      for (final p
          in payload['plugins'] is List ? payload['plugins'] as List : const [])
        if (p is Map && p['pluginId'] is String) p,
    ];
    _order = [for (final p in entries) p['pluginId'] as String];
    _mainsInLayer = this.layer == null
        ? const {}
        : {
            for (final p in entries)
              if (p['onePage'] == true &&
                  p['panels'] is List &&
                  (p['panels'] as List).any(
                    (x) => x is Map && x['placement'] == 'chat',
                  ))
                p['pluginId'] as String,
          };
    const body =
        'return window.glazePlugins ? window.glazePlugins.setup(payload) : -1;';
    final layer = this.layer;
    // The layer first: the chat page tells it its insets as it sets up, and
    // its main scripts may emit to the panels right away.
    if (layer != null) {
      final count = await layer.callAsyncJs(
        body,
        arguments: {
          'payload': {...payload, 'layer': 'panels'},
        },
      );
      if (count is! num || count < 0) {
        debugPrint('[PluginRuntime] plugin host missing in the plugin layer');
      }
      if (_disposed) return;
    }
    final count = await bridge.callAsyncJs(
      body,
      arguments: {
        'payload': layer == null ? payload : {...payload, 'layer': 'chat'},
      },
    );
    _ready = count is num && count >= 0;
    if (!_ready) debugPrint('[PluginRuntime] plugin host missing in WebView');
  }

  Future<void> teardown() async {
    _ready = false;
    const body =
        'if (window.glazePlugins) window.glazePlugins.teardown(); return true;';
    await Future.wait([
      bridge.callAsyncJs(body),
      if (layer != null) layer!.callAsyncJs(body),
    ]);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(bridge.onPluginRequest, service.dispatch)) {
      bridge.onPluginRequest = null;
    }
    final layer = this.layer;
    if (layer != null) {
      bridge.onPluginEmit = null;
      bridge.onPluginInsets = null;
      layer.onPluginEmit = null;
      if (identical(layer.onPluginRequest, service.dispatch)) {
        layer.onPluginRequest = null;
      }
    }
    unawaited(teardown().catchError((Object _) {}));
  }

  void _relayEmit(
    Future<Object?> Function(String, {Map<String, dynamic> arguments}) call,
    Map<String, dynamic> emit,
  ) {
    if (_disposed || emit['pluginId'] is! String) return;
    unawaited(
      call(
        'window.glazePlugins.relayEmit(pluginId, event, detail); return true;',
        arguments: {
          'pluginId': emit['pluginId'],
          'event': emit['event'],
          'detail': emit['detail'],
        },
      ).catchError((Object _) => null),
    );
  }

  /// Delivers [event] to [pluginId]'s frames as if one of them had emitted
  /// it, in the page its main script is in.
  void emitTo(String pluginId, String event, Object? detail) {
    if (!isReady) return;
    unawaited(
      _mainPage(pluginId)(
        'window.glazePlugins.relayEmit(pluginId, event, detail); return true;',
        arguments: {'pluginId': pluginId, 'event': event, 'detail': detail},
      ).catchError((Object _) => null),
    );
  }

  /// Runs [body] in the chat page only.
  void _fire(String body, Map<String, dynamic> arguments) {
    if (!isReady) return;
    unawaited(
      bridge
          .callAsyncJs('$body return true;', arguments: arguments)
          .catchError((Object _) => null),
    );
  }

  /// Runs [body] in the chat page and in the plugin layer.
  void _fireAll(String body, Map<String, dynamic> arguments) {
    _fire(body, arguments);
    final layer = this.layer;
    if (!isReady || layer == null) return;
    unawaited(
      layer
          .callAsyncJs('$body return true;', arguments: arguments)
          .catchError((Object _) => null),
    );
  }

  void dispatchEvent(String type, Map<String, Object?> payload) =>
      _fireAll('window.glazePlugins.dispatchEvent(type, payload);', {
        'type': type,
        'payload': {...payload, 'at': DateTime.now().toUtc().toIso8601String()},
      });

  void pushVars(String pluginId, String scope, Map<String, dynamic> root) =>
      _fireAll('window.glazePlugins.pushVars(pluginId, scope, value);', {
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
    const body = 'window.glazePlugins.updateLocalization(list); return true;';
    await Future.wait([
      bridge.callAsyncJs(body, arguments: {'list': entries}),
      if (layer != null) layer!.callAsyncJs(body, arguments: {'list': entries}),
    ]);
  }

  Future<Map<String, dynamic>?> _intercept(
    String type,
    Map<String, Object?> payload,
  ) async {
    if (!isReady) return null;
    final full = {
      ...payload,
      'chatId': chatId(),
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      if (_mainsInLayer.isEmpty) {
        final result = await bridge.callAsyncJs(
          'return await window.glazePlugins.intercept(type, payload);',
          arguments: {'type': type, 'payload': full},
          timeout: const Duration(seconds: 130),
        );
        return result is Map ? Map<String, dynamic>.from(result) : null;
      }
      // Main scripts in both pages: each run of plugins that are in the same
      // page in turn, so the plugin order holds.
      var text = full['text'];
      for (var i = 0; i < _order.length;) {
        final page = _mainPage(_order[i]);
        final run = <String>[];
        while (i < _order.length && _mainPage(_order[i]) == page) {
          run.add(_order[i++]);
        }
        final result = await page(
          'return await window.glazePlugins.intercept(type, payload, only);',
          arguments: {
            'type': type,
            'payload': {...full, 'text': text},
            'only': run,
          },
          timeout: const Duration(seconds: 130),
        );
        if (result is! Map) continue;
        if (result['text'] is String) text = result['text'];
        if (result['cancelled'] == true) {
          return Map<String, dynamic>.from(result);
        }
      }
      return {'text': text, 'cancelled': false};
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
      final result = await _mainPage(pluginId)(
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
        value: result['value'],
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
      // A handler the main script registered is there; one with its own
      // scripts gets a frame of its own in the same page.
      final result = await _mainPage(pluginId)(
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
