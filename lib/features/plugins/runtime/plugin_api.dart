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

/// A write that needs the user's consent before the first time a plugin does
/// it (unless they chose "always allow" for that plugin).
enum PluginConsent { library, images }

/// What the user answered to a consent sheet.
enum PluginConsentAnswer { deny, once, always }

/// One option of `glaze.ui.select` / `ask`.
typedef PluginOption = ({String value, String label, String? description});

/// A file picked through `glaze.files.pick`.
typedef PickedPluginFile = ({String name, Uint8List bytes});

/// Everything the API needs that shows UI. Implemented by the chat host;
/// faked in tests.
abstract interface class PluginUi {
  void toast(String text);
  Future<void> openUrl(String url);
  Future<String?> select(
    List<PluginOption> options, {
    String? title,
    String? defaultValue,
  });
  Future<Map<String, Object?>> ask({
    required String question,
    required List<PluginOption> options,
    required bool allowOther,
    String? placeholder,
    String? defaultValue,
  });
  Future<PluginConsentAnswer> consent({
    required String pluginName,
    required PluginConsent kind,
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

  /// Called after a variable write so every frame's sync cache follows.
  void variablesChanged(String scope, Map<String, dynamic> root);
}

/// One bridged call, already attributed to [plugin] by the WebView host.
class PluginCall {
  const PluginCall({
    required this.plugin,
    required this.host,
    required this.method,
    required this.params,
    this.messageId,
    this.requestConsent,
    this.invoker,
  });

  final InstalledPlugin plugin;
  final PluginApiHost host;
  final String method;

  /// Positional arguments.
  final Object? params;

  /// Message a message panel is attached to (set by the host, never by the
  /// plugin); null for other frames.
  final String? messageId;

  /// Asks the user (once, or until they allow it for good) before a write
  /// the method's static [PluginMethod.consent] could not decide up front.
  final Future<void> Function(PluginConsent kind, String summary)?
  requestConsent;

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

  Future<void> consent(PluginConsent kind, String summary) async {
    final ask = requestConsent;
    if (ask != null) await ask(kind, summary);
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

/// A bridged method, the manifest permission it needs (null = none) and the
/// consent it asks for.
class PluginMethod {
  const PluginMethod(this.run, {this.permission, this.consent, this.summary});
  final PluginOperation run;
  final String? permission;
  final PluginConsent? consent;

  /// Translation key describing the write in the consent sheet.
  final String? summary;
}
