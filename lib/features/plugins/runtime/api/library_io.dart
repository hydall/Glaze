import 'dart:convert';

import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'files_api.dart';

/// An import source: an object, or a virtual path to a JSON file in the
/// plugin's files.
Future<Map<String, dynamic>> readImportSource(PluginCall c) async {
  final source = c.arg(0);
  if (source is Map) return Map<String, dynamic>.from(source);
  if (source is String) {
    if (!c.plugin.allows(PluginPermission.files)) {
      throw const PluginApiError(
        'permission_denied',
        'Importing from a file needs the "files" permission',
      );
    }
    final decoded = jsonDecode(utf8.decode(await readPluginFile(c, source)));
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  throw const PluginApiError(
    'invalid_arguments',
    'Pass an object or a JSON file path',
  );
}

/// `export(id, { format: 'object' | 'json' })`: the object itself, or a JSON
/// file written to the plugin's files.
Future<Object?> exportJson(
  PluginCall c,
  Map<String, dynamic> object,
  String name,
) async {
  if (c.mapArg(1)['format'] == 'object') return object;
  if (!c.plugin.allows(PluginPermission.files)) {
    throw const PluginApiError(
      'permission_denied',
      'Exporting to a file needs the "files" permission',
    );
  }
  return savePluginFile(
    c,
    '${safeFileName(name, 'export')}.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(object)),
  );
}

String? refId(Object? v) => (v is Map ? v['id'] : v)?.toString();

/// Library-write method with the shared permission and consent.
PluginMethod libraryWrite(PluginOperation run, String summary) => PluginMethod(
  run,
  permission: PluginPermission.library,
  consent: PluginConsent.library,
  summary: summary,
);
