import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/plugins/plugin_hooks.dart';
import '../../chat/bridge/chat_bridge_controller.dart';
import 'tavo_bridge_service.dart';

/// Result of a native-triggered plugin action.
class PluginActionResult {
  const PluginActionResult({required this.ok, this.reason, this.message});
  final bool ok;
  final String? reason;
  final String? message;
}

/// Drives the plugin frames inside one chat WebView: setup/teardown, event
/// fan-out, blocking hooks and native actions. Owns no Riverpod state; the
/// host widget feeds it.
class PluginChatRuntime implements PluginHookRunner {
  PluginChatRuntime({
    required this.bridge,
    required this.service,
    required this.chatId,
    required this.onCancelledSend,
  }) {
    bridge.onTavoRequest = service.dispatch;
  }

  final ChatBridgeController bridge;
  final TavoBridgeService service;

  /// Current session id; read on every event.
  final String? Function() chatId;

  /// Shows the plugin's reason when `input:beforeSend` cancels.
  final void Function(String? message) onCancelledSend;

  bool _disposed = false;
  bool _ready = false;

  bool get isReady => _ready && !_disposed;

  /// (Re)creates every plugin frame from [payload]. Entry scripts rerun.
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
    if (identical(bridge.onTavoRequest, service.dispatch)) {
      bridge.onTavoRequest = null;
    }
    unawaited(teardown().catchError((Object _) {}));
  }

  void dispatchEvent(String type, Map<String, Object?> payload) {
    if (!isReady) return;
    unawaited(
      bridge
          .callAsyncJs(
            'window.glazePlugins.dispatchEvent(type, payload); return true;',
            arguments: {
              'type': type,
              'payload': {
                ...payload,
                'at': DateTime.now().toUtc().toIso8601String(),
              },
            },
          )
          .catchError((Object _) => null),
    );
  }

  void pushVars(String scope, Map<String, dynamic> root) {
    if (!isReady) return;
    unawaited(
      bridge
          .callAsyncJs(
            'window.glazePlugins.pushVars(scope, value); return true;',
            arguments: {'scope': scope, 'value': root},
          )
          .catchError((Object _) => null),
    );
  }

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
    final result = await _intercept('input:beforeSend', {
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
  void notify(String type, Map<String, Object?> payload) =>
      dispatchEvent(type, payload);

  /// Runs an `inputActions:` / `sidebar:` / `lastMessageActions:` handler.
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
}
