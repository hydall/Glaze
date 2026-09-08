import 'dart:convert';

import 'package:drift/drift.dart';

import '../../db/app_db.dart';
import '../../utils/time_helpers.dart';
import '../image_storage_service.dart';
import 'backup_helpers.dart';
import 'js_memory_importer.dart';
import 'js_message_normalizer.dart';

class JsChatImporter extends BackupHelpers {
  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;

  JsChatImporter(this.db, this.imageStorage);

  Future<void> importChats(Map<String, dynamic> kv) async {
    final validCharIds = await _loadCharacterIds();

    await importChatsFromMap(kv, 'gz_chat_', validCharIds);

    final topLevelChats = kv['chats'];
    if (topLevelChats is Map<String, dynamic>) {
      for (final entry in topLevelChats.entries) {
        final charId = entry.key;
        final chatData = entry.value as Map<String, dynamic>?;
        if (chatData == null) continue;
        if (!validCharIds.contains(charId)) continue;
        await importChatData(charId, chatData);
      }
    }
  }

  Future<Set<String>> _loadCharacterIds() async {
    final rows = await db.select(db.characters).get();
    return rows.map((r) => r.charId).toSet();
  }

  Future<void> importChatsFromMap(
      Map<String, dynamic> kv, String prefix, Set<String> validCharIds) async {
    final chatKeys = kv.keys.where((k) => k.startsWith(prefix));

    for (final key in chatKeys) {
      final charId = key.substring(prefix.length);
      final chatData = kv[key] as Map<String, dynamic>?;
      if (chatData == null) continue;
      if (!validCharIds.contains(charId)) continue;
      await importChatData(charId, chatData);
    }
  }

  Future<void> importChatData(
      String charId, Map<String, dynamic> chatData) async {
    if (charId == 'undefined' || charId.isEmpty) return;
    final sessions = chatData['sessions'] as Map<String, dynamic>?;
    if (sessions == null) return;

    final authorsNotesRaw = chatData['authorsNotes'] is Map<String, dynamic>
        ? chatData['authorsNotes'] as Map<String, dynamic>
        : null;

    for (final sessionEntry in sessions.entries) {
      final sessionIdx = int.tryParse(sessionEntry.key) ?? 0;
      final rawMessages = sessionEntry.value;
      if (rawMessages is! List) continue;

      final typedMessages = rawMessages.whereType<Map<String, dynamic>>().toList();
      final messages = typedMessages.asMap().entries.map((e) {
        return normalizeJsMessage(e.value, charId, sessionIdx, e.key);
      }).toList();

      final sessionId = '${charId}_$sessionIdx';
      final chatUpdatedAt = toInt(chatData['updatedAt']);
      final anRaw = authorsNotesRaw?[sessionEntry.key];
      final authorsNoteJson = encodeAuthorsNote(anRaw);
      final draft =
          chatData['draft'] is String ? chatData['draft'] as String : null;
      final scrollAnchor = chatData['lastScrollAnchor'] is Map
          ? jsonEncode(chatData['lastScrollAnchor'])
          : null;
      await db.into(db.chatSessions).insertOnConflictUpdate(
            ChatSessionsCompanion.insert(
              sessionId: sessionId,
              characterId: charId,
              sessionIndex: sessionIdx,
              messagesJson: jsonEncode(messages),
              updatedAt:
                  Value(chatUpdatedAt ?? currentTimestampSeconds()),
              authorsNoteJson: Value(authorsNoteJson),
              draft: Value(draft),
              lastScrollAnchorJson: Value(scrollAnchor),
            ),
          );
    }

    final currentId = toInt(chatData['currentId']);
    if (currentId != null) {
      await (db.update(db.characters)
            ..where((t) => t.charId.equals(charId)))
          .write(CharactersCompanion(
        currentSessionIndex: Value(currentId),
      ));
    }

    final memoryImporter = JsMemoryImporter(db);
    final memoryBooksRaw = _decodeIfString(chatData['memoryBooks']);
    await memoryImporter.importMemoryBooks(charId, memoryBooksRaw);

    final pendingDraftsRaw = _decodeIfString(chatData['pendingDrafts']);
    await memoryImporter.importMemoryDrafts(charId, pendingDraftsRaw);
  }

  dynamic _decodeIfString(dynamic value) {
    if (value is String && value.isNotEmpty) {
      try {
        return jsonDecode(value);
      } catch (_) {}
    }
    return value;
  }
}
