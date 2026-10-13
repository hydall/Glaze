import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/composer_text_bridge.dart';
import '../models/installed_plugin.dart';
import 'plugin_file_store.dart';
import 'plugin_variable_store.dart';

/// Error surfaced to plugin code as `error.code` / `error.message`.
class PluginApiError implements Exception {
  const PluginApiError(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// What the user answered to a consent sheet.
enum PluginConsentAnswer { deny, once, always }

/// One option of `glaze.ui.select` / `ask`.
typedef PluginOption = ({String value, String label, String? description});

/// A file picked through `glaze.files.pick`.
typedef PickedPluginFile = ({String name, Uint8List bytes});

/// Everything the API needs that shows UI. Implemented by the chat host;
/// faked in tests.
/// Toasts and sheets a plugin opens are signed with [pluginName], so a plugin
/// cannot pass its own question off as the app's.
abstract interface class PluginUi {
  void toast(String pluginName, String text);
  Future<void> openUrl(String url);
  Future<String?> select(
    String pluginName,
    List<PluginOption> options, {
    String? title,
    String? defaultValue,
  });
  Future<Map<String, Object?>> ask({
    required String pluginName,
    required String question,
    required List<PluginOption> options,
    required bool allowOther,
    String? placeholder,
    String? defaultValue,
  });

  /// Null when the sheet was dismissed or could not be shown.
  Future<PluginConsentAnswer?> consent({
    required String pluginName,
    required String permission,
    required String summary,
  });
  Future<void> previewImage(Uint8List bytes);
  Future<void> share(Uint8List bytes, String filename);
  Future<List<PickedPluginFile>> pickFiles({
    required bool multiple,
    List<String>? extensions,
  });
  Future<void> openChat(String characterId, int sessionIndex);
}

/// The app side of one chat's plugin runtime.
abstract interface class PluginApiHost {
  /// Character the chat screen is showing (chat provider family key).
  String get charId;
  String? get sessionId;

  /// A long-lived provider [Ref] for reading app state and services.
  Ref get ref;
  PluginUi get ui;
  PluginVariableStore get variables;
  PluginFileStore files(String pluginId);
  ComposerTextAccess? composer();

  /// Called after a variable write so the plugin's frames' sync caches
  /// follow.
  void variablesChanged(
    String pluginId,
    String scope,
    Map<String, dynamic> root,
  );

  /// Records that [pluginId] reached, or was stopped from reaching, [host]
  /// through the app.
  void networkUsed(String pluginId, String host, {required bool blocked});

  /// Notes in [pluginId]'s history that it was let through to do what
  /// [actionKey] (see [pluginActionKey]) names.
  void allowed(String pluginId, String actionKey);

  /// Tells the user [pluginName] was stopped from doing what [actionKey]
  /// (see [pluginActionKey]) names and notes it in the plugin's history;
  /// [shown] is false when the user just said no themselves.
  void denied(
    String pluginId,
    String pluginName,
    String actionKey, {
    bool shown = true,
  });
}

/// Translation key naming an attempt: the method's summary, else the
/// permission's name.
String pluginActionKey(String permission, String? summary) =>
    summary ?? 'plugins_permission_name_${permission.replaceAll('.', '_')}';

/// One bridged call, already attributed to [plugin] by the WebView host.
class PluginCall {
  const PluginCall({
    required this.plugin,
    required this.pluginName,
    required this.host,
    required this.method,
    required this.params,
    this.messageId,
    this.requirePermission,
    this.invoker,
  });

  final InstalledPlugin plugin;

  /// [plugin]'s name in the user's language, for what the user sees.
  final String pluginName;
  final PluginApiHost host;
  final String method;

  /// Positional arguments.
  final Object? params;

  /// Message a message panel is attached to (set by the host, never by the
  /// plugin); null for other frames.
  final String? messageId;

  /// Checks a permission the method's static [PluginMethod.permission]
  /// could not decide up front, asking the user when it is one that asks.
  final Future<void> Function(String permission, String? summary)?
  requirePermission;

  /// Runs another bridged method as the same plugin (permission checks
  /// included); used by `commands.run`.
  final Future<Object?> Function(String method, Object? params)? invoker;

  Ref get ref => host.ref;

  Future<Object?> invoke(String method, Object? params) {
    final run = invoker;
    if (run == null) {
      throw const PluginApiError('unavailable', 'Nested calls are unavailable');
    }
    return run(method, params);
  }

  /// Throws `permission_denied` unless the plugin may use [permission];
  /// [summary] is the translation key naming the attempt.
  Future<void> require(String permission, [String? summary]) async {
    final check = requirePermission;
    if (check != null) {
      await check(permission, summary);
    } else if (!plugin.allows(permission)) {
      throw PluginApiError(
        'permission_denied',
        'This needs the "$permission" permission',
      );
    }
  }

  Object? arg(int index) {
    final p = params;
    if (p is List) return index < p.length ? p[index] : null;
    return index == 0 ? p : null;
  }

  Map<String, dynamic> mapArg(int index) {
    final v = arg(index);
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  String requireString(int index, String what) {
    final v = arg(index);
    if (v is! String || v.isEmpty) {
      throw PluginApiError('invalid_arguments', '$what must be a string');
    }
    return v;
  }

  String requireSession() {
    final id = host.sessionId;
    if (id == null) throw const PluginApiError('no_chat', 'No chat is open');
    return id;
  }
}

typedef PluginOperation = Future<Object?> Function(PluginCall call);

/// A bridged method and the manifest permission it needs (null = none). A
/// permission in [PluginPermission.asking] also asks the user.
class PluginMethod {
  const PluginMethod(
    this.run, {
    this.permission,
    this.summary,
    this.internal = false,
    this.exposedBy = const [],
  });
  final PluginOperation run;
  final String? permission;

  /// For a method whose permission depends on its arguments (checked when
  /// it runs): the manifest permissions that make it part of the API.
  final List<String> exposedBy;

  /// Called by the host page on the plugin's behalf, not part of the API.
  final bool internal;

  /// Translation key describing the attempt in the consent sheet and the
  /// plugin's history.
  final String? summary;
}
