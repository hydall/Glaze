import 'dart:convert';
import 'dart:io';

// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/services/chat_import_export.dart';
import '../../../../core/state/active_selection_provider.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/state/lorebook_provider.dart';
import '../../../../core/utils/time_helpers.dart';
import '../../../chat/chat_actions_service.dart';
import '../../../chat/chat_provider.dart';
import '../../../chat/chat_session_service.dart';
import '../../../chat_history/chat_history_provider.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';
import 'files_api.dart';
import 'shapes.dart';

/// `glaze.chats.*`. A chat is one session of one character; its id is the
/// session id.
Map<String, PluginMethod> chatsApi() => {
  'chats.current': const PluginMethod(_current),
  'chats.get': const PluginMethod(_get),
  'chats.find': const PluginMethod(_find),
  'chats.create': const PluginMethod(
    _create,
    consent: PluginConsent.library,
    summary: 'plugins_consent_chat_create',
  ),
  'chats.update': const PluginMethod(_update),
  'chats.open': const PluginMethod(_open),
  'chats.copy': const PluginMethod(
    _copy,
    consent: PluginConsent.library,
    summary: 'plugins_consent_chat_copy',
  ),
  'chats.remove': const PluginMethod(
    _remove,
    consent: PluginConsent.library,
    summary: 'plugins_consent_chat_remove',
  ),
  'chats.export': const PluginMethod(
    _export,
    permission: PluginPermission.files,
  ),
  'chats.inspectImport': const PluginMethod(
    _inspectImport,
    permission: PluginPermission.files,
  ),
  'chats.import': const PluginMethod(
    _import,
    permission: PluginPermission.files,
    consent: PluginConsent.library,
    summary: 'plugins_consent_chat_import',
  ),
};

Future<ChatSession?> _session(PluginCall c, String id) async {
  final open = c.ref.read(chatProvider(c.host.charId)).value?.session;
  if (open?.id == id) return open;
  return c.ref.read(chatRepoProvider).getById(id);
}

/// The `glaze.chats` object for [s].
Future<Map<String, Object?>> chatJson(PluginApiHost host, ChatSession s) async {
  final ref = host.ref;
  final character = await ref
      .read(characterRepoProvider)
      .getById(s.characterId);
  final persona = ref.read(
    effectivePersonaForChatProvider((charId: s.characterId, sessionId: s.id)),
  );
  final preset = ref.read(
    effectivePresetForChatProvider((charId: s.characterId, sessionId: s.id)),
  );
  final books = ref.read(lorebooksProvider).value ?? const [];
  final attached = ref.read(lorebookActivationsProvider).chat[s.id] ?? [];
  return {
    'id': s.id,
    'characterId': s.characterId,
    'index': s.sessionIndex,
    'name': s.sessionVars['sessionName'] ?? '',
    'characters': [if (character != null) characterSummary(character)],
    'persona': persona == null
        ? null
        : {'id': persona.id, 'name': personaName(persona)},
    'preset': preset == null ? null : {'id': preset.id, 'name': preset.name},
    'lorebooks': [
      for (final b in books)
        if (attached.contains(b.id) ||
            (b.activationScope == 'chat' && b.activationTargetId == s.id))
          {'id': b.id, 'name': b.name},
    ],
    'messageCount': s.messages.length,
    'updatedAt': s.updatedAt,
    'current': s.id == host.sessionId,
  };
}

Future<Object?> _current(PluginCall c) async {
  final s = c.ref.read(chatProvider(c.host.charId)).value?.session;
  return s == null ? null : chatJson(c.host, s);
}

Future<Object?> _get(PluginCall c) async {
  final s = await _session(c, c.requireString(0, 'id'));
  return s == null ? null : chatJson(c.host, s);
}

Future<Object?> _find(PluginCall c) async {
  final options = c.mapArg(0);
  final name = options['name'];
  final characterId = options['characterId']?.toString();
  final all = await c.ref.read(chatRepoProvider).getAllSessionMetadata();
  return [
    for (final m in all)
      if ((characterId == null || m.characterId == characterId) &&
          (name is! String ||
              nameMatches(m.sessionName ?? '', name, options['match'])))
        {
          'id': m.sessionId,
          'characterId': m.characterId,
          'index': m.sessionIndex,
          'name': m.sessionName ?? '',
          'messageCount': m.messageCount,
          'updatedAt': m.updatedAt,
          'current': m.sessionId == c.host.sessionId,
        },
  ];
}

Future<Object?> _create(PluginCall c) async {
  final data = c.mapArg(0);
  final characterId = data['characterId']?.toString() ?? c.host.charId;
  if (await c.ref.read(characterRepoProvider).getById(characterId) == null) {
    throw PluginApiError('not_found', 'No character $characterId');
  }
  final session = await ChatSessionService(c.ref).createNewSession(characterId);
  final name = data['name'];
  if (name is String && name.trim().isNotEmpty) {
    await c.ref
        .read(chatHistoryProvider.notifier)
        .renameSession(session.id, name.trim());
  }
  c.ref.invalidate(chatHistoryProvider);
  return session.id;
}

Future<Object?> _update(PluginCall c) async {
  final data = c.mapArg(0);
  final id = data['id']?.toString() ?? c.requireSession();
  final session = await _session(c, id);
  if (session == null) throw PluginApiError('not_found', 'No chat $id');
  if (id != c.host.sessionId) {
    await c.consent(PluginConsent.library, 'plugins_consent_chat_update');
  } else if (!c.plugin.manifest.hasPermission(PluginPermission.messages)) {
    throw const PluginApiError(
      'permission_denied',
      'chats.update needs the "messages" permission',
    );
  }
  final name = data['name'];
  if (name is String) {
    await c.ref.read(chatHistoryProvider.notifier).renameSession(id, name);
  }
  String? refId(Object? v) => v is Map ? v['id']?.toString() : v?.toString();
  if (data.containsKey('persona')) {
    setPersonaConnectionRef(c.ref, 'chat', id, refId(data['persona']));
  }
  if (data.containsKey('preset')) {
    setPresetConnectionRef(c.ref, 'chat', id, refId(data['preset']));
  }
  if (data['lorebooks'] is List) {
    final ids = [
      for (final b in data['lorebooks'] as List)
        if (refId(b) case final String bookId) bookId,
    ];
    final current = c.ref.read(lorebookActivationsProvider);
    final chat = {...current.chat};
    if (ids.isEmpty) {
      chat.remove(id);
    } else {
      chat[id] = ids;
    }
    final updated = current.copyWith(chat: chat);
    c.ref.read(lorebookActivationsProvider.notifier).state = updated;
    await saveLorebookActivations(updated);
  }
  return id;
}

Future<Object?> _open(PluginCall c) async {
  final id = c.requireString(0, 'id');
  final session = await _session(c, id);
  if (session == null) return null;
  if (id == c.host.sessionId) return id;
  if (session.characterId == c.host.charId) {
    await c.ref
        .read(chatProvider(c.host.charId).notifier)
        .switchSession(session.sessionIndex);
  } else {
    await c.host.ui.openChat(session.characterId, session.sessionIndex);
  }
  return id;
}

Future<ChatSession> _insertCopy(
  PluginCall c,
  String characterId,
  List<ChatMessage> messages, {
  Map<String, String> sessionVars = const {},
}) async {
  final repo = c.ref.read(chatRepoProvider);
  final existing = await repo.getByCharacterId(characterId);
  var index =
      existing.fold<int>(0, (m, s) => s.sessionIndex > m ? s.sessionIndex : m) +
      1;
  while (true) {
    final session = ChatSession(
      id: '${characterId}_$index',
      characterId: characterId,
      sessionIndex: index,
      messages: messages,
      sessionVars: sessionVars,
      updatedAt: currentTimestampSeconds(),
    );
    if (await repo.insertIfAbsent(session)) {
      ChatSessionService.updateCache(session);
      c.ref.invalidate(chatHistoryProvider);
      return session;
    }
    index++;
  }
}

Future<Object?> _copy(PluginCall c) async {
  final id = c.requireString(0, 'id');
  final source = await _session(c, id);
  if (source == null) throw PluginApiError('not_found', 'No chat $id');
  final copy = await _insertCopy(
    c,
    source.characterId,
    source.messages,
    sessionVars: source.sessionVars,
  );
  return copy.id;
}

Future<Object?> _remove(PluginCall c) async {
  final id = c.requireString(0, 'id');
  if (await _session(c, id) == null) return null;
  await c.ref.read(chatHistoryProvider.notifier).deleteSession(id);
  return id;
}

Future<Object?> _export(PluginCall c) async {
  final id = c.arg(0)?.toString() ?? c.requireSession();
  final session = await _session(c, id);
  if (session == null) throw PluginApiError('not_found', 'No chat $id');
  final character = await c.ref
      .read(characterRepoProvider)
      .getById(session.characterId);
  if (character == null) throw PluginApiError('not_found', 'No character');
  final persona = c.ref.read(
    effectivePersonaForChatProvider((
      charId: session.characterId,
      sessionId: session.id,
    )),
  );
  final tmp = await getTemporaryDirectory();
  final result = await exportChatAsJsonl(
    session: session,
    character: character,
    outputDir: tmp.path,
    userName: persona == null ? 'User' : personaName(persona),
  );
  final file = File(result.filePath);
  final bytes = await file.readAsBytes();
  await file.delete().catchError((_) => file);
  return savePluginFile(
    c,
    '${safeFileName(character.name, 'chat')} ${session.sessionIndex}.jsonl',
    bytes,
  );
}

Future<ChatImportResult> _readImport(PluginCall c) async {
  final bytes = await readPluginFile(c, c.requireString(0, 'path'));
  try {
    return importChatFromJsonlString(utf8.decode(bytes));
  } catch (e) {
    throw PluginApiError('invalid_file', 'Not a chat file: $e');
  }
}

Future<Object?> _inspectImport(PluginCall c) async {
  final result = await _readImport(c);
  return {'messageCount': result.messages.length, 'userName': result.userName};
}

Future<Object?> _import(PluginCall c) async {
  final result = await _readImport(c);
  final characterId = c.mapArg(1)['characterId']?.toString() ?? c.host.charId;
  final saved = await c.ref
      .read(chatActionsServiceProvider)
      .importChatFromResult(characterId, result);
  return saved.sessionId;
}
