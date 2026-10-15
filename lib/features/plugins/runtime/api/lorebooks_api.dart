import '../../../../core/import/st_lorebook_importer.dart';
import '../../../../core/llm/lorebook_limits.dart';
import '../../../../core/models/lorebook.dart';
import '../../../../core/services/st_lorebook_exporter.dart';
import '../../../../core/state/lorebook_provider.dart';
import '../../../../core/utils/id_generator.dart';
import '../../../chat/state/lorebook_coverage_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'library_io.dart';
import 'shapes.dart';

/// `glaze.lorebooks.*` (objects are Glaze lorebooks; import also takes
/// SillyTavern World Info and `character_book`). Attach a book to a chat
/// with `glaze.chats.update({ lorebooks })`.
Map<String, PluginMethod> lorebooksApi() => {
  'lorebooks.list': libraryRead(PluginPermission.lorebooksRead, _list),
  'lorebooks.get': libraryRead(PluginPermission.lorebooksRead, _get),
  'lorebooks.find': libraryRead(PluginPermission.lorebooksRead, _find),
  'lorebooks.coverage': libraryRead(PluginPermission.lorebooksRead, _coverage),
  'lorebooks.create': libraryCreate(
    PluginPermission.lorebooksCreate,
    _create,
    'plugins_consent_lorebook_create',
  ),
  'lorebooks.update': libraryUpdate(
    PluginPermission.lorebooksUpdate,
    _update,
    'plugins_consent_lorebook_update',
  ),
  'lorebooks.remove': libraryDelete(
    PluginPermission.lorebooksDelete,
    _remove,
    'plugins_consent_lorebook_remove',
  ),
  'lorebooks.import': libraryCreate(
    PluginPermission.lorebooksCreate,
    _import,
    'plugins_consent_lorebook_import',
  ),
  'lorebooks.export': libraryRead(PluginPermission.lorebooksRead, _export),
};

Future<List<Lorebook>> _all(PluginCall c) =>
    c.ref.read(lorebooksProvider.future);

Future<Lorebook?> _byId(PluginCall c, Object? id) async {
  final key = refId(id);
  return (await _all(c)).where((b) => b.id == key).firstOrNull;
}

Future<Object?> _list(PluginCall c) async => [
  for (final b in await _all(c))
    {'id': b.id, 'name': b.name, 'entryCount': b.entries.length},
];

Future<Object?> _get(PluginCall c) async =>
    (await _byId(c, c.arg(0)))?.toJson();

Future<Object?> _find(PluginCall c) async {
  final query = c.requireString(0, 'name');
  final match = c.mapArg(1)['match'];
  return [
    for (final b in await _all(c))
      if (nameMatches(b.name, query, match)) b.toJson(),
  ];
}

/// The engine's own reading of which lorebook entries the open chat will
/// inject, and why — the same [computeLorebookCoverage] dry run the Prompt
/// Inspector and the context card use, so a tracker built on it can never
/// disagree with the prompt the model receives. Reads the chat's messages,
/// hence both `library.read.lorebooks` (the method's permission) and
/// `messages`.
///
/// `entry.probability` is the one rule the dry run does not reproduce: it
/// reports a sub-100% entry as it would be at 100%, so the same chat does not
/// flip between calls.
Future<Object?> _coverage(PluginCall c) async {
  await c.require(PluginPermission.messages);
  final result = await c.ref.read(
    lorebookCoverageProvider(c.host.charId).future,
  );
  final settings = c.ref.read(lorebookSettingsProvider);
  return {
    'entries': [
      for (final e in result.entries)
        {
          'id': e.id,
          'comment': e.comment,
          'content': e.content,
          'position': e.position,
          'order': e.order,
          'lorebookId': e.lorebookId,
          'lorebookName': e.lorebookName,
          'constant': e.constant,
          'activated': e.activated,
          'matchedKeys': e.matchedKeys,
          'matchedSecondaryKeys': e.matchedSecondaryKeys,
          'matchMessageIndex': e.matchMessageIndex,
          'cutOff': e.cutOff?.name,
          'recursionPass': e.recursionPass,
          'stickyHeld': e.stickyHeld,
          'onCooldown': e.onCooldown,
        },
    ],
    'totalCandidates': result.totalCandidates,
    'activatedCount': result.activatedCount,
    'cutOffCount': result.cutOffCount,
    'injectedCount': result.injectedCount,
    'inactiveCount': result.inactiveCount,
    'settings': {
      ...settings.toJson(),
      'entryCap': resolveGlobalEntryCap(settings),
    },
  };
}

Lorebook _fromJson(Map<String, dynamic> data, String id) {
  final entries = [
    for (final e
        in (data['entries'] is List ? data['entries'] as List : const []))
      if (e is Map) {'id': generateId(), ...Map<String, dynamic>.from(e)},
  ];
  return Lorebook.fromJson({
    ...data,
    'id': id,
    'entries': entries,
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
  });
}

Future<Object?> _create(PluginCall c) async {
  final data = c.mapArg(0);
  if (data['name'] is! String) {
    throw const PluginApiError('invalid_arguments', 'name is required');
  }
  final book = _fromJson(data, generateId());
  await c.ref.read(lorebooksProvider.notifier).addLorebook(book);
  return book.id;
}

Future<Object?> _update(PluginCall c) async {
  final data = c.mapArg(0);
  final existing = await _byId(c, data['id']);
  if (existing == null) {
    throw PluginApiError('not_found', 'No lorebook ${data['id']}');
  }
  final book = _fromJson({...existing.toJson(), ...data}, existing.id);
  await c.ref.read(lorebooksProvider.notifier).updateLorebook(book);
  return book.id;
}

Future<Object?> _remove(PluginCall c) async {
  final b = await _byId(c, c.arg(0));
  if (b == null) return null;
  await c.ref.read(lorebooksProvider.notifier).deleteLorebook(b.id);
  return b.id;
}

Future<Object?> _import(PluginCall c) async {
  final json = await readImportSource(c);
  final isGlaze =
      json['entries'] is List &&
      (json['entries'] as List).every((e) => e is Map && e['keys'] is List) &&
      json.containsKey('activationScope');
  final Lorebook book;
  if (isGlaze) {
    book = _fromJson(json, generateId());
  } else {
    try {
      book = importSTLorebook(
        json,
        nameOverride: json['name']?.toString() ?? 'Imported',
      ).lorebook;
    } catch (e) {
      throw PluginApiError('invalid_file', 'Not a lorebook: $e');
    }
  }
  await c.ref.read(lorebooksProvider.notifier).put(book);
  return book.id;
}

Future<Object?> _export(PluginCall c) async {
  final b = await _byId(c, c.arg(0));
  if (b == null) return null;
  if (c.mapArg(1)['format'] == 'object') return b.toJson();
  return exportJson(c, glazeLorebookToSTJson(b), b.name);
}
