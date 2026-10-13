import 'package:flutter/foundation.dart';

import '../models/installed_plugin.dart';
import 'api/characters_api.dart';
import 'api/chats_api.dart';
import 'api/commands_api.dart';
import 'api/files_api.dart';
import 'api/generation_api.dart';
import 'api/lorebooks_api.dart';
import 'api/memory_api.dart';
import 'api/messages_api.dart';
import 'api/personas_api.dart';
import 'api/presets_api.dart';
import 'api/regex_api.dart';
import 'api/themes_api.dart';
import 'api/ui_api.dart';
import 'api/variables_api.dart';
import 'plugin_api.dart';

/// Every bridged `glaze.*` method. The SDK only exposes the ones a plugin's
/// manifest grants, and [PluginBridgeService.dispatch] re-checks each call.
final Map<String, PluginMethod> pluginMethodRegistry = Map.unmodifiable({
  ...variablesApi(),
  ...messagesApi(),
  ...chatsApi(),
  ...charactersApi(),
  ...personasApi(),
  ...presetsApi(),
  ...lorebooksApi(),
  ...regexApi(),
  ...memoryApi(),
  ...themesApi(),
  ...filesApi(),
  ...generationApi(),
  ...uiApi(),
  ...commandsApi(),
});

/// Methods [plugin] may call: those with no permission plus those whose
/// permission its manifest lists.
List<String> pluginMethodsFor(InstalledPlugin plugin) => [
  for (final e in pluginMethodRegistry.entries)
    if (e.value.permission == null || plugin.allows(e.value.permission!)) e.key,
];

/// Dispatches `{pluginId, method, params, messageId?}` requests from the
/// chat WebView's plugin host.
///
/// Result envelope: `{ok: true, result}` or
/// `{ok: false, error: {code, message}}`.
class PluginBridgeService {
  PluginBridgeService({
    required this.host,
    required this.pluginById,
    required this.pluginName,
    required this.consentText,
    required this.onAlwaysAllow,
  });

  final PluginApiHost host;

  /// Looks up an *enabled* plugin; a disabled or unknown id is rejected.
  final InstalledPlugin? Function(String id) pluginById;
  final String Function(InstalledPlugin plugin) pluginName;

  /// Resolves a consent summary key to the user's language.
  final String Function(String key) consentText;

  /// Persists "always allow" for a plugin.
  final Future<void> Function(String pluginId, PluginConsent kind)
  onAlwaysAllow;

  final Map<String, Set<PluginConsent>> _allowed = {};
  Future<void> _consentQueue = Future.value();

  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> request) async {
    final pluginId = request['pluginId'];
    final method = request['method'];
    if (pluginId is! String || method is! String) {
      return _error('invalid_request', 'Malformed plugin request');
    }
    final plugin = pluginById(pluginId);
    if (plugin == null) {
      return _error('permission_denied', 'Plugin "$pluginId" is not enabled');
    }
    try {
      final result = await _invoke(
        plugin,
        method,
        request['params'],
        request['messageId'] as String?,
      );
      return {'ok': true, 'result': result};
    } on PluginApiError catch (e) {
      return _error(e.code, e.message);
    } on ArgumentError catch (e) {
      return _error('invalid_arguments', '${e.message}');
    } on StateError catch (e) {
      return _error('operation_failed', e.message);
    } catch (e) {
      debugPrint('[PluginBridge] $pluginId $method failed: $e');
      return _error('operation_failed', e.toString());
    }
  }

  Future<Object?> _invoke(
    InstalledPlugin plugin,
    String method,
    Object? params,
    String? messageId,
  ) async {
    final entry = pluginMethodRegistry[method];
    if (entry == null) {
      throw PluginApiError('unknown_method', 'Unknown method $method');
    }
    final permission = entry.permission;
    if (permission != null && !plugin.allows(permission)) {
      throw PluginApiError(
        'permission_denied',
        '$method needs the "$permission" permission',
      );
    }
    if (entry.consent case final kind?) {
      await _consent(plugin, kind, entry.summary ?? method);
    }
    return entry.run(
      PluginCall(
        plugin: plugin,
        host: host,
        method: method,
        params: params,
        messageId: messageId,
        requestConsent: (kind, summary) => _consent(plugin, kind, summary),
        invoker: (m, p) => _invoke(plugin, m, p, messageId),
      ),
    );
  }

  /// Asks once per plugin and kind at a time; "always" is remembered for
  /// good, "once" only for this call.
  Future<void> _consent(
    InstalledPlugin plugin,
    PluginConsent kind,
    String summaryKey,
  ) {
    final run = _consentQueue.then((_) async {
      if (plugin.grants.contains(kind.name) ||
          (_allowed[plugin.id]?.contains(kind) ?? false)) {
        return;
      }
      final answer = await host.ui.consent(
        pluginName: pluginName(plugin),
        kind: kind,
        summary: consentText(summaryKey),
      );
      switch (answer) {
        case PluginConsentAnswer.deny:
          throw const PluginApiError('user_denied', 'The user declined');
        case PluginConsentAnswer.once:
          return;
        case PluginConsentAnswer.always:
          (_allowed[plugin.id] ??= {}).add(kind);
          await onAlwaysAllow(plugin.id, kind);
      }
    });
    _consentQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Map<String, dynamic> _error(String code, String message) => {
    'ok': false,
    'error': {'code': code, 'message': message},
  };
}
