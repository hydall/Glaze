import 'package:flutter/foundation.dart';

import '../models/installed_plugin.dart';
import 'tavo_call.dart';
import 'tavo_data_api.dart';
import 'tavo_file_api.dart';
import 'tavo_host.dart';
import 'tavo_ui_api.dart';

/// Every bridged `tavo.*` method. The SDK only exposes the ones a plugin's
/// manifest grants, and [TavoBridgeService.dispatch] re-checks on each call.
final Map<String, TavoMethod> tavoMethodRegistry = Map.unmodifiable({
  ...tavoDataMethods(),
  ...tavoUiMethods(),
  ...tavoFileMethods(),
});

/// Methods [plugin] may call: those with no permission plus those whose
/// permission its manifest declares.
List<String> tavoMethodsFor(InstalledPlugin plugin) => [
  for (final e in tavoMethodRegistry.entries)
    if (e.value.permission == null ||
        plugin.manifest.hasPermission(e.value.permission!))
      e.key,
];

/// Dispatches `{pluginId, surface, method, params}` requests from the chat
/// WebView's plugin host to the registered operations.
///
/// Result envelope: `{ok: true, result}` or
/// `{ok: false, error: {code, message}}`.
class TavoBridgeService {
  TavoBridgeService({required this.host, required this.pluginById});

  final TavoHost host;

  /// Looks up an *enabled* plugin; a disabled or unknown id is rejected.
  final InstalledPlugin? Function(String id) pluginById;

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
    final entry = tavoMethodRegistry[method];
    if (entry == null) {
      return _error('unknown_method', 'Unknown method $method');
    }
    final permission = entry.permission;
    if (permission != null && !plugin.manifest.hasPermission(permission)) {
      return _error(
        'permission_denied',
        '$method needs the "$permission" permission',
      );
    }
    try {
      final result = await entry.run(
        TavoCall(
          plugin: plugin,
          host: host,
          method: method,
          params: request['params'],
        ),
      );
      return {'ok': true, 'result': result};
    } on TavoError catch (e) {
      return _error(e.code, e.message);
    } on ArgumentError catch (e) {
      return _error('invalid_arguments', '${e.message}');
    } on StateError catch (e) {
      return _error('operation_failed', e.message);
    } catch (e) {
      debugPrint('[TavoBridge] $pluginId $method failed: $e');
      return _error('operation_failed', e.toString());
    }
  }

  static Map<String, dynamic> _error(String code, String message) => {
    'ok': false,
    'error': {'code': code, 'message': message},
  };
}
