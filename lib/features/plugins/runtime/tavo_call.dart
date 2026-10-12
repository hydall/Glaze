import '../models/installed_plugin.dart';
import 'tavo_host.dart';

/// Error surfaced to plugin code as `error.code` / `error.message`.
class TavoError implements Exception {
  const TavoError(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// One `tavo.*` call, already attributed to [plugin] by the WebView host.
class TavoCall {
  const TavoCall({
    required this.plugin,
    required this.host,
    required this.method,
    required this.params,
  });

  final InstalledPlugin plugin;
  final TavoHost host;
  final String method;

  /// Positional arguments (SDK namespace methods) or a named-argument map
  /// (variables, storage).
  final Object? params;

  Object? arg(int index) {
    final p = params;
    if (p is List) return index < p.length ? p[index] : null;
    return index == 0 ? p : null;
  }

  Object? named(String key) {
    final p = params;
    return p is Map ? p[key] : null;
  }

  Map<String, dynamic> mapArg(int index) {
    final v = arg(index);
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  String requireString(int index, String what) {
    final v = arg(index);
    if (v is! String) {
      throw TavoError('invalid_arguments', '$what must be a string');
    }
    return v;
  }
}

typedef TavoOperation = Future<Object?> Function(TavoCall call);

/// A bridged method and the manifest permission it needs (null = none).
class TavoMethod {
  const TavoMethod(this.run, {this.permission});
  final TavoOperation run;
  final String? permission;
}
