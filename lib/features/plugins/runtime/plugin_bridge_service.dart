import 'package:flutter/foundation.dart';

import '../models/installed_plugin.dart';
import '../models/plugin_manifest.dart';
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
/// manifest asks for, and [PluginBridgeService.dispatch] checks each call
/// against what the user allowed.
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
  'events.subscribe': const PluginMethod(_subscribe, internal: true),
});

/// The permission each kind of hook or notification needs.
const Map<String, String> pluginEventPermissions = {
  'send': PluginPermission.composer,
  'generation': PluginPermission.generate,
  'chat': PluginPermission.messages,
  'message': PluginPermission.messages,
};

/// Kinds of hooks and notifications [plugin] receives.
List<String> pluginEventsFor(InstalledPlugin plugin) => [
  for (final e in pluginEventPermissions.entries)
    if (plugin.allows(e.value)) e.key,
];

/// The host page asks when a plugin subscribes to a kind of event it is not
/// allowed: the check refuses it, which tells the user.
Future<Object?> _subscribe(PluginCall c) async {
  final permission = pluginEventPermissions[c.arg(0)];
  if (permission == null) {
    throw const PluginApiError('invalid_arguments', 'Unknown event kind');
  }
  await c.require(permission);
  return true;
}

/// Methods [plugin] sees: those with no permission plus those whose
/// permission its manifest lists. One the user switched off stays, so a call
/// is refused with a toast rather than failing as a missing function.
List<String> pluginMethodsFor(InstalledPlugin plugin) => [
  for (final e in pluginMethodRegistry.entries)
    if (!e.value.internal &&
        (e.value.permission == null ||
            plugin.manifest.hasPermission(e.value.permission!)))
      e.key,
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
    required this.text,
    required this.onAlwaysAllow,
    required this.onDeny,
  });

  final PluginApiHost host;

  /// Looks up an *enabled* plugin; a disabled or unknown id is rejected.
  /// Read on every check, so answers saved meanwhile count.
  final InstalledPlugin? Function(String id) pluginById;
  final String Function(InstalledPlugin plugin) pluginName;

  /// Resolves a translation key to the user's language.
  final String Function(String key) text;

  /// Persists "always allow" for a permission that asks.
  final Future<void> Function(String pluginId, String permission) onAlwaysAllow;

  /// Persists "deny": the permission is switched off.
  final Future<void> Function(String pluginId, String permission) onDeny;

  final Map<String, Set<String>> _allowed = {};
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
    if (entry.permission case final permission?) {
      await _require(plugin, permission, entry.summary);
    }
    return entry.run(
      PluginCall(
        plugin: plugin,
        host: host,
        method: method,
        params: params,
        messageId: messageId,
        requirePermission: (permission, summary) =>
            _require(plugin, permission, summary),
        invoker: (m, p) => _invoke(plugin, m, p, messageId),
      ),
    );
  }

  /// What the plugin tried, for the consent sheet.
  String _action(String permission, String? summary) {
    final key = pluginActionKey(permission, summary);
    final described = text(key);
    return described == key && summary == null ? permission : described;
  }

  /// Lets the call through when the plugin may use [permission]; one that
  /// asks shows the consent sheet unless the user allowed it for good. A
  /// plugin that was refused is not asked again: it gets a toast and an
  /// entry in its history instead.
  Future<void> _require(
    InstalledPlugin plugin,
    String permission,
    String? summary,
  ) async {
    void refuse({bool shown = true}) {
      host.denied(
        plugin.id,
        pluginName(plugin),
        pluginActionKey(permission, summary),
        shown: shown,
      );
      throw PluginApiError(
        'permission_denied',
        'This needs the "$permission" permission',
      );
    }

    final live = pluginById(plugin.id) ?? plugin;
    if (!live.allows(permission)) refuse();
    if (!PluginPermission.asking.contains(permission)) return;

    final run = _consentQueue.then((_) async {
      final current = pluginById(plugin.id) ?? plugin;
      if (!current.allows(permission)) refuse();
      if (current.grants.contains(permission) ||
          (_allowed[plugin.id]?.contains(permission) ?? false)) {
        return;
      }
      final answer = await host.ui.consent(
        pluginName: pluginName(current),
        permission: permission,
        summary: _action(permission, summary),
      );
      switch (answer) {
        case null:
          throw const PluginApiError('user_denied', 'The user declined');
        case PluginConsentAnswer.deny:
          await onDeny(plugin.id, permission);
          refuse(shown: false);
        case PluginConsentAnswer.once:
          return;
        case PluginConsentAnswer.always:
          (_allowed[plugin.id] ??= {}).add(permission);
          await onAlwaysAllow(plugin.id, permission);
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
