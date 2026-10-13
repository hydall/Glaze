import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import '../../../../core/models/character.dart';
import '../../../../core/services/character_export_helper.dart';
import '../../../../core/services/character_exporter.dart';
import '../../../../core/services/file_export_result.dart';
import '../../../../core/state/character_provider.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/lorebook_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../character_list/character_import_persistence_provider.dart';
import '../../../../core/services/character_import_persistence_coordinator.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'files_api.dart';
import 'shapes.dart';

/// `glaze.characters.*`.
Map<String, PluginMethod> charactersApi() => {
  'characters.list': const PluginMethod(_list),
  'characters.get': const PluginMethod(_get),
  'characters.find': const PluginMethod(_find),
  'characters.current': const PluginMethod(_current),
  'characters.create': const PluginMethod(
    _create,
    permission: PluginPermission.library,
    consent: PluginConsent.library,
    summary: 'plugins_consent_character_create',
  ),
  'characters.update': const PluginMethod(
    _update,
    permission: PluginPermission.library,
    consent: PluginConsent.library,
    summary: 'plugins_consent_character_update',
  ),
  'characters.remove': const PluginMethod(
    _remove,
    permission: PluginPermission.library,
    consent: PluginConsent.library,
    summary: 'plugins_consent_character_remove',
  ),
  'characters.import': const PluginMethod(
    _import,
    permission: PluginPermission.library,
    consent: PluginConsent.library,
    summary: 'plugins_consent_character_import',
  ),
  'characters.export': const PluginMethod(_export),
};

Future<List<Character>> _all(PluginCall c) =>
    c.ref.read(charactersProvider.future);

Future<Character?> _byId(PluginCall c, Object? id) async {
  final key = id is Map ? id['id'] : id;
  if (key == null) return null;
  return c.ref.read(characterRepoProvider).getById(key.toString());
}

Future<Object?> _list(PluginCall c) async => [
  for (final ch in await _all(c))
    if (!ch.hidden) characterSummary(ch),
];

Future<Object?> _get(PluginCall c) async {
  final ch = await _byId(c, c.arg(0));
  return ch == null ? null : characterJson(ch);
}

Future<Object?> _current(PluginCall c) async {
  final ch = await _byId(c, c.host.charId);
  return ch == null ? null : characterJson(ch);
}

Future<Object?> _find(PluginCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  return [
    for (final ch in await _all(c))
      if (nameMatches(ch.name, query, match) ||
          nameMatches(characterName(ch), query, match))
        characterJson(ch),
  ];
}

Future<Object?> _create(PluginCall c) async {
  final data = c.mapArg(0);
  final name = data['name'];
  if (name is! String || name.trim().isEmpty) {
    throw const PluginApiError('invalid_arguments', 'name is required');
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  final ch = applyCharacterJson(
    Character(id: generateId(), name: name, createdAt: now, updatedAt: now),
    data,
  );
  await c.ref.read(charactersProvider.notifier).add(ch);
  return ch.id;
}

Future<Object?> _update(PluginCall c) async {
  final data = c.mapArg(0);
  final existing = await _byId(c, data['id']);
  if (existing == null) {
    throw PluginApiError('not_found', 'No character ${data['id']}');
  }
  await c.ref
      .read(charactersProvider.notifier)
      .save(applyCharacterJson(existing, data));
  return existing.id;
}

Future<Object?> _remove(PluginCall c) async {
  final ch = await _byId(c, c.arg(0));
  if (ch == null) return null;
  await c.ref.read(charactersProvider.notifier).remove(ch.id);
  return ch.id;
}

Future<Object?> _import(PluginCall c) async {
  final source = c.arg(0);
  final Uint8List bytes;
  final String fileName;
  if (source is Map) {
    bytes = Uint8List.fromList(utf8.encode(jsonEncode(source)));
    fileName = 'card.json';
  } else if (source is String) {
    if (!c.plugin.allows(PluginPermission.files)) {
      throw const PluginApiError(
        'permission_denied',
        'Importing from a file needs the "files" permission',
      );
    }
    bytes = await readPluginFile(c, source);
    fileName = source.split('/').last;
  } else {
    throw const PluginApiError(
      'invalid_arguments',
      'Pass a card or a file path',
    );
  }
  final importer = await c.ref.read(characterImporterProvider.future);
  final result = await importer.importFromBytes(bytes, fileName);
  final persisted = await c.ref
      .read(characterImportPersistenceCoordinatorProvider)
      .persist(result);
  switch (persisted) {
    case CharacterImportPersistenceFailure():
      throw PluginApiError('import_failed', '${persisted.error}');
    case CharacterImportPersistenceSuccess():
      return {
        'characterId': persisted.character.id,
        'lorebookId': persisted.lorebook?.id,
      };
  }
}

Future<Object?> _export(PluginCall c) async {
  final ch = await _byId(c, c.arg(0));
  if (ch == null) return null;
  final format = c.mapArg(1)['format'] ?? 'json';
  final book = buildCharacterBookData(
    c.ref.read(lorebooksProvider).value ?? const [],
    ch.id,
  );
  final tmp = await getTemporaryDirectory();
  final FileExportResult result;
  if (format == 'png') {
    result = await exportCharacterAsPng(
      character: ch,
      avatarBytes: await resolveCharacterAvatarBytes(ch),
      outputDir: tmp.path,
      includeCharacterBook: book != null,
      characterBookData: book,
    );
  } else {
    result = await exportCharacterAsJson(
      character: ch,
      outputDir: tmp.path,
      includeCharacterBook: book != null,
      characterBookData: book,
    );
  }
  final file = File(result.filePath);
  final bytes = await file.readAsBytes();
  await file.delete().catchError((_) => file);
  if (format == 'object') return jsonDecode(utf8.decode(bytes));
  if (!c.plugin.allows(PluginPermission.files)) {
    throw const PluginApiError(
      'permission_denied',
      'Exporting to a file needs the "files" permission',
    );
  }
  return savePluginFile(
    c,
    '${safeFileName(ch.name, 'character')}.${format == 'png' ? 'png' : 'json'}',
    bytes,
  );
}
