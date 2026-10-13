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
    await c.require(PluginPermission.files);
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
  await c.require(PluginPermission.files);
  return savePluginFile(
    c,
    '${safeFileName(name, 'export')}.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(object)),
  );
}

String? refId(Object? v) => (v is Map ? v['id'] : v)?.toString();

/// Library method reading one kind of item; [permission] is that kind's
/// read permission.
PluginMethod libraryRead(String permission, PluginOperation run) =>
    PluginMethod(run, permission: permission);

/// Library method that adds things.
PluginMethod libraryCreate(PluginOperation run, String summary) => PluginMethod(
  run,
  permission: PluginPermission.libraryCreate,
  summary: summary,
);

/// Library method that changes things.
PluginMethod libraryUpdate(PluginOperation run, String summary) => PluginMethod(
  run,
  permission: PluginPermission.libraryUpdate,
  summary: summary,
);

/// Library method that deletes things.
PluginMethod libraryDelete(PluginOperation run, String summary) => PluginMethod(
  run,
  permission: PluginPermission.libraryDelete,
  summary: summary,
);
