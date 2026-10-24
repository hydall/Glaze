import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../debug/perf_debug.dart';
import '../../llm/prompt/exact_lorebook_manifest.dart';
import 'lorebook_use_manifest_repo.dart';
import 'session_deletion_queries.dart';
import '../../models/chat_message.dart';
import '../../application/sync_repo_interfaces.dart';

class _PreparedUserMessageAppend {
  const _PreparedUserMessageAppend({
    required this.messagesJson,
    required this.messages,
    this.didAppend = true,
  });

  final String messagesJson;
  final List<ChatMessage> messages;
  final bool didAppend;
}

class ChatRepo implements SyncChatStore {
  final AppDatabase _db;
  ChatRepo(this._db);

  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

  Future<List<ChatSession>> getByCharacterId(String charId) async {
    final rows = await (_db.select(
      _db.chatSessions,
    )..where((t) => t.characterId.equals(charId))).get();
    return [for (final row in rows) await _toModelAsync(row)];
  }

  /// Lightweight per-character session listing: counts and previews are
  /// projected in SQL, so no message is decoded. Use this when only session
  /// indexes/counts are needed (e.g. the "Open chat" picker) — the full
  /// [getByCharacterId] decodes all messages and is noticeably slower for
  /// characters with large histories.
  Future<List<SessionMetadata>> getMetadataByCharacterId(String charId) async {
    final rows = await _db
        .customSelect(
          '$_sessionMetadataSql WHERE character_id = ? ORDER BY session_index',
          variables: [Variable.withString(charId)],
          readsFrom: {_db.chatSessions},
        )
        .get();
    return rows.map(_projectedMetadata).toList();
  }

  /// How many chat sessions one character has, aggregated in SQL.
  ///
  /// The Quick Access session card needs the number and nothing else;
  /// [getByCharacterId] would decode every message of every session just to
  /// read `.length` off the result.
  Future<int> countByCharacterId(String charId) async {
    final countExpr = _db.chatSessions.sessionId.count();
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([countExpr])
      ..where(_db.chatSessions.characterId.equals(charId));
    final row = await query.getSingleOrNull();
    return row?.read(countExpr) ?? 0;
  }

  /// Number of chat sessions per character id, aggregated in SQL.
  ///
  /// Feeds the variations sheet, where "how many chats does this variation
  /// have" is the fact that tells two same-looking variations apart. Counting
  /// via [getAllSessionMetadata] would decode every session's messages just to
  /// throw them away.
  Stream<Map<String, int>> watchSessionCountsByCharacter() {
    final countExpr = _db.chatSessions.sessionId.count();
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([_db.chatSessions.characterId, countExpr])
      ..groupBy([_db.chatSessions.characterId]);
    return query.watch().map((rows) {
      final counts = <String, int>{};
      for (final row in rows) {
        final charId = row.read(_db.chatSessions.characterId);
        if (charId == null || charId.isEmpty) continue;
        counts[charId] = row.read(countExpr) ?? 0;
      }
      return counts;
    });
  }

  Future<List<ChatSession>> getAllSessions() async {
    final rows = await (_db.select(
      _db.chatSessions,
    )..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])).get();
    return [for (final row in rows) await _toModelAsync(row)];
  }

  /// What the chat list shows of a session, read in SQL: the count, the
  /// first message's time and the last message, never the blob itself. A
  /// long chat is tens of megabytes of JSON, and the whole table is hundreds;
  /// handing that to Dart to scan for a count froze the app for half a
  /// second — on every write to any chat, through [watchAllSessionMetadata].
  static const _sessionMetadataSql = '''
SELECT
  session_id,
  character_id,
  session_index,
  updated_at,
  session_vars_json,
  json_array_length(messages_json) AS message_count,
  json_extract(messages_json, '\$[0].timestamp') AS first_timestamp,
  json_extract(messages_json, '\$[#-1]') AS last_message_json
FROM chat_sessions''';

  @override
  Future<List<SessionMetadata>> getAllSessionMetadata() async {
    final rows = await _db
        .customSelect(
          '$_sessionMetadataSql ORDER BY updated_at DESC',
          readsFrom: {_db.chatSessions},
        )
        .get();
    return rows.map(_projectedMetadata).toList();
  }

  /// [getAllSessionMetadata], re-run on every write to the table. The
  /// projection runs in the database's isolate; what reaches this one is a
  /// few hundred bytes per session.
  Stream<List<SessionMetadata>> watchAllSessionMetadata() {
    var lastEmit = <SessionMetadata>[];
    return _db
        .customSelect(
          '$_sessionMetadataSql ORDER BY updated_at DESC',
          readsFrom: {_db.chatSessions},
        )
        .watch()
        .map((rows) {
          final meta = rows.map(_projectedMetadata).toList();
          if (_metadataEqual(lastEmit, meta)) return lastEmit;
          lastEmit = meta;
          return meta;
        });
  }

  static bool _metadataEqual(List<SessionMetadata> a, List<SessionMetadata> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].sessionId != b[i].sessionId ||
          a[i].updatedAt != b[i].updatedAt ||
          a[i].messageCount != b[i].messageCount ||
          a[i].sessionName != b[i].sessionName) {
        return false;
      }
    }
    return true;
  }

  /// How many characters of JSON [sessionId]'s messages take, without reading
  /// them; null for a session that does not exist. A cheap way to tell a
  /// chat worth loading ahead of time from one that is not.
  Future<int?> messagesJsonLength(String sessionId) async {
    final length = _db.chatSessions.messagesJson.length;
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([length])
      ..where(_db.chatSessions.sessionId.equals(sessionId));
    final row = await query.getSingleOrNull();
    return row?.read(length);
  }

  /// The character [sessionId] belongs to, without reading its messages.
  Future<String?> characterIdOf(String sessionId) async {
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([_db.chatSessions.characterId])
      ..where(_db.chatSessions.sessionId.equals(sessionId));
    final row = await query.getSingleOrNull();
    return row?.read(_db.chatSessions.characterId);
  }

  @override
  Future<ChatSession?> getById(String sessionId) async {
    final row = await (_db.select(
      _db.chatSessions,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
    return row != null ? await _toModelAsync(row) : null;
  }

  @override
  Future<void> put(ChatSession session) async {
    await _db
        .into(_db.chatSessions)
        .insertOnConflictUpdate(await _toCompanionAsync(session));
  }

  /// Writes [sessions] in a single batch, so the reactive watchers emit
  /// **one** update instead of one per session (the mass-import path).
  Future<void> putAll(List<ChatSession> sessions) async {
    if (sessions.isEmpty) return;
    final companions = [
      for (final session in sessions) await _toCompanionAsync(session),
    ];
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(_db.chatSessions, companions);
    });
  }

  /// Inserts a newly allocated session without replacing an existing owner of
  /// the same globally unique session id.
  Future<bool> insertIfAbsent(ChatSession session) async {
    final inserted = await _db
        .into(_db.chatSessions)
        .insertReturningOrNull(
          await _toCompanionAsync(session),
          mode: InsertMode.insertOrIgnore,
        );
    return inserted != null;
  }

  /// Atomically appends a user message and clears the draft.
  ///
  /// This avoids the send path writing a whole stale session blob while the
  /// input draft debounce is also persisting. The returned session is the
  /// durable DB state that generation should use for prompt assembly.
  Future<ChatSession?> appendUserMessageAndClearDraft({
    required String sessionId,
    required ChatMessage message,
    required int updatedAt,
  }) async {
    while (true) {
      final snapshot = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (snapshot == null) return null;

      final prepared = await _prepareUserMessageAppend(
        snapshot.messagesJson,
        message,
      );

      final result = await _db.transaction<({bool retry, ChatSession? value})>(
        () async {
          final current = await (_db.select(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
          if (current == null) return (retry: false, value: null);
          if (current.messagesJson != snapshot.messagesJson) {
            return (retry: true, value: null);
          }
          await (_db.update(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).write(
            ChatSessionsCompanion(
              messagesJson: Value(prepared.messagesJson),
              draft: const Value(''),
              updatedAt: Value(updatedAt),
            ),
          );
          return (
            retry: false,
            value: _toModel(
              current.copyWith(
                messagesJson: prepared.messagesJson,
                draft: const Value(''),
                updatedAt: updatedAt,
              ),
              messages: prepared.messages,
            ),
          );
        },
      );
      if (!result.retry) return result.value;
    }
  }

  /// Atomically appends a user message, clears the draft, and records that the
  /// caller-observed assistant variation was accepted.
  ///
  /// The assistant identity is a compare-and-swap guard: selection may change
  /// between the UI capturing it and this transaction reading the session. A
  /// legacy variation without a manifest remains sendable; an immutable
  /// manifest, when present, must receive its acceptance in this transaction.
  Future<ChatSession?> appendUserMessageAndAcceptCurrentVariation({
    required String sessionId,
    required ChatMessage message,
    required LorebookUseGenerationIdentity expectedPrecedingAssistant,
    required int updatedAt,
  }) async {
    if (expectedPrecedingAssistant.sessionId != sessionId) {
      return null;
    }
    while (true) {
      final snapshot = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (snapshot == null) return null;

      final prepared = await _prepareAcceptedUserMessageAppend(
        messagesJson: snapshot.messagesJson,
        message: message,
        expectedPrecedingAssistant: expectedPrecedingAssistant,
      );
      if (prepared == null) return null;

      // A retry after a completed transaction must not append the same user
      // message or a second acceptance event. The draft still has to go: this
      // branch reports the send as accepted, and the session it returns is
      // published into `ChatState` and the session cache, so a draft left on
      // it is the text of the message that was just sent — sitting in the
      // composer again the next time the chat is opened.
      if (!prepared.didAppend) {
        if ((snapshot.draft ?? '').isEmpty) {
          return _toModel(snapshot, messages: prepared.messages);
        }
        await (_db.update(_db.chatSessions)
              ..where((t) => t.sessionId.equals(sessionId)))
            .write(const ChatSessionsCompanion(draft: Value('')));
        return _toModel(
          snapshot.copyWith(draft: const Value('')),
          messages: prepared.messages,
        );
      }

      final result = await _db.transaction<({bool retry, ChatSession? value})>(
        () async {
          final row = await (_db.select(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
          if (row == null) return (retry: false, value: null);
          if (row.messagesJson != snapshot.messagesJson) {
            return (retry: true, value: null);
          }

          final manifest =
              await (_db.select(_db.lorebookUseManifests)
                    ..where((t) => t.sessionId.equals(sessionId))
                    ..where(
                      (t) => t.messageId.equals(
                        expectedPrecedingAssistant.messageId,
                      ),
                    )
                    ..where(
                      (t) =>
                          t.swipeId.equals(expectedPrecedingAssistant.swipeId),
                    )
                    ..where(
                      (t) => t.agentSwipeId.equals(
                        expectedPrecedingAssistant.agentSwipeId,
                      ),
                    ))
                  .getSingleOrNull();

          await (_db.update(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).write(
            ChatSessionsCompanion(
              messagesJson: Value(prepared.messagesJson),
              draft: const Value(''),
              updatedAt: Value(updatedAt),
            ),
          );

          if (manifest != null) {
            await LorebookUseManifestRepo(_db).insertVariationAcceptance(
              acceptanceId: 'variation:$sessionId:${message.id}',
              identity: expectedPrecedingAssistant,
              acceptedByUserMessageId: message.id,
              acceptedAt: updatedAt,
            );
          }

          return (
            retry: false,
            value: _toModel(
              row.copyWith(
                messagesJson: prepared.messagesJson,
                draft: const Value(''),
                updatedAt: updatedAt,
              ),
              messages: prepared.messages,
            ),
          );
        },
      );
      if (!result.retry) return result.value;
    }
  }

  /// Updates only the draft column, and only if [expectedMessageCount] still
  /// matches the row. A delayed input debounce from before Send must not write
  /// an old draft over a session that has since gained the user message.
  ///
  /// Returns the draft that landed, or null when the row had moved on. The
  /// messages are neither read nor decoded: the count comes from SQL, and the
  /// caller already holds the session the draft belongs to.
  Future<String?> updateDraftIfMessageCount({
    required String sessionId,
    required String draft,
    required int expectedMessageCount,
  }) async {
    return _db.transaction(() async {
      final row = await _db
          .customSelect(
            'SELECT json_array_length(messages_json) AS message_count '
            'FROM chat_sessions WHERE session_id = ?',
            variables: [Variable.withString(sessionId)],
            readsFrom: {_db.chatSessions},
          )
          .getSingleOrNull();
      if (row == null) return null;
      if (row.readNullable<int>('message_count') != expectedMessageCount) {
        return null;
      }

      await (_db.update(_db.chatSessions)
            ..where((t) => t.sessionId.equals(sessionId)))
          .write(ChatSessionsCompanion(draft: Value(draft)));

      return draft;
    });
  }

  /// Atomically transforms the latest durable message list for a session.
  ///
  /// The callback runs inside the database transaction, so callers never have
  /// to persist a full session snapshot captured before another mutation.
  Future<ChatSession?> mutateMessages({
    required String sessionId,
    required List<ChatMessage> Function(List<ChatMessage> messages) mutate,
    required int updatedAt,
  }) async {
    return mutateSession(
      sessionId: sessionId,
      updatedAt: updatedAt,
      mutate: (session) => session.copyWith(
        messages: mutate(List<ChatMessage>.from(session.messages)),
      ),
    );
  }

  Future<ChatSession?> mutateMessagesWithBeforeWrite({
    required String sessionId,
    required List<ChatMessage> Function(List<ChatMessage> messages) mutate,
    required int updatedAt,
    required Future<void> Function(ChatSession before, ChatSession after)
    beforeWrite,
  }) => _mutateSession(
    sessionId: sessionId,
    updatedAt: updatedAt,
    mutate: (session) => session.copyWith(
      messages: mutate(List<ChatMessage>.from(session.messages)),
    ),
    beforeWrite: beforeWrite,
  );

  /// Atomically transforms one message identified by its durable ID.
  Future<ChatSession?> mutateMessage({
    required String sessionId,
    required String messageId,
    required ChatMessage? Function(ChatMessage message) mutate,
    required int updatedAt,
  }) {
    return mutateSession(
      sessionId: sessionId,
      updatedAt: updatedAt,
      mutate: (session) {
        final index = session.messages.indexWhere(
          (message) => message.id == messageId,
        );
        if (index < 0) return null;
        final updatedMessage = mutate(session.messages[index]);
        if (updatedMessage == null) return null;
        final messages = List<ChatMessage>.from(session.messages);
        messages[index] = updatedMessage;
        return session.copyWith(messages: messages);
      },
    );
  }

  /// Atomically updates only the author's note against the latest session.
  Future<ChatSession?> mutateAuthorsNote({
    required String sessionId,
    required AuthorsNote? Function(AuthorsNote? note) mutate,
    required int updatedAt,
  }) {
    return mutateSession(
      sessionId: sessionId,
      updatedAt: updatedAt,
      mutate: (session) =>
          session.copyWith(authorsNote: mutate(session.authorsNote)),
    );
  }

  /// Atomically renames a session without replacing other session variables.
  Future<ChatSession?> renameSession({
    required String sessionId,
    required String name,
  }) {
    return mutateSession(
      sessionId: sessionId,
      mutate: (session) => session.copyWith(
        sessionVars: {...session.sessionVars, 'sessionName': name},
      ),
    );
  }

  /// Atomically transforms the latest durable chat session while preserving
  /// columns the callback did not change.
  Future<ChatSession?> mutateSession({
    required String sessionId,
    required ChatSession? Function(ChatSession session) mutate,
    int? updatedAt,
  }) => _mutateSession(
    sessionId: sessionId,
    mutate: mutate,
    updatedAt: updatedAt,
  );

  Future<ChatSession?> _mutateSession({
    required String sessionId,
    required ChatSession? Function(ChatSession session) mutate,
    int? updatedAt,
    Future<void> Function(ChatSession before, ChatSession after)? beforeWrite,
  }) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return null;

      final current = await _toModelAsync(row);
      final updated = mutate(current);
      if (updated == null) return null;
      if (beforeWrite != null) await beforeWrite(current, updated);
      final messagesJson = await _encodeMessagesAsync(updated.messages);
      final sessionVarsJson = updated.sessionVars.isNotEmpty
          ? jsonEncode(updated.sessionVars)
          : null;
      final authorsNoteJson = updated.authorsNote != null
          ? jsonEncode(updated.authorsNote!.toJson())
          : null;
      final lastScrollAnchorJson = updated.lastScrollAnchor.isNotEmpty
          ? jsonEncode(updated.lastScrollAnchor)
          : null;
      final durableUpdatedAt = updatedAt ?? updated.updatedAt;

      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          messagesJson: Value(messagesJson),
          sessionVarsJson: Value(sessionVarsJson),
          authorsNoteJson: Value(authorsNoteJson),
          draft: Value(updated.draft),
          lastScrollAnchorJson: Value(lastScrollAnchorJson),
          updatedAt: Value(durableUpdatedAt),
        ),
      );

      // What was written, as it was written: decoding the blob again to say
      // so cost as much as decoding it the first time.
      return updated.copyWith(updatedAt: durableUpdatedAt);
    });
  }

  /// Commits a generated assistant variation and, when supplied, its exact
  /// lorebook-use manifest in one database transaction.  The message mutation
  /// deliberately mirrors the guarded generation commit path: a stale regen
  /// cannot attach provenance (or replace text) after its anchor changed.
  Future<ChatSession?> commitGenerationResult({
    required ChatSession baseSession,
    required ChatSession generatedSession,
    required String? regenTargetId,
    ExactLorebookManifest? manifest,
    Future<void> Function(ChatSession before, ChatSession after)? beforeWrite,
  }) async {
    return _db.transaction(() async {
      final row =
          await (_db.select(_db.chatSessions)
                ..where((table) => table.sessionId.equals(generatedSession.id)))
              .getSingleOrNull();
      if (row == null) return null;

      final latest = await _toModelAsync(row);
      final messages = List<ChatMessage>.from(latest.messages);
      ChatMessage? committed;
      if (regenTargetId != null) {
        final baseIndex = baseSession.messages.indexWhere(
          (message) => message.id == regenTargetId,
        );
        final generatedIndex = generatedSession.messages.indexWhere(
          (message) => message.id == regenTargetId,
        );
        final latestIndex = messages.indexWhere(
          (message) => message.id == regenTargetId,
        );
        if (baseIndex < 0 || generatedIndex < 0 || latestIndex < 0) {
          return null;
        }
        final base = baseSession.messages[baseIndex];
        final current = messages[latestIndex];
        if (!_sameGenerationAnchor(base, current)) return null;
        committed = generatedSession.messages[generatedIndex].copyWith(
          isHidden: current.isHidden,
          imageHidden: current.imageHidden,
        );
        messages[latestIndex] = committed;
      } else {
        if (generatedSession.messages.length !=
            baseSession.messages.length + 1) {
          return null;
        }
        final expectedTail = baseSession.messages.lastOrNull?.id;
        final currentTail = messages.lastOrNull?.id;
        if (expectedTail != currentTail) return null;
        committed = generatedSession.messages.last;
        messages.add(committed);
      }

      final updated = latest.copyWith(
        messages: messages,
        sessionVars: applySessionVarDelta(
          latest.sessionVars,
          baseSession.sessionVars,
          generatedSession.sessionVars,
        ),
      );
      if (beforeWrite != null) await beforeWrite(latest, updated);
      final messagesJson = await _encodeMessagesAsync(updated.messages);
      final sessionVarsJson = updated.sessionVars.isNotEmpty
          ? jsonEncode(updated.sessionVars)
          : null;
      final authorsNoteJson = updated.authorsNote != null
          ? jsonEncode(updated.authorsNote!.toJson())
          : null;
      final lastScrollAnchorJson = updated.lastScrollAnchor.isNotEmpty
          ? jsonEncode(updated.lastScrollAnchor)
          : null;

      await (_db.update(
        _db.chatSessions,
      )..where((table) => table.sessionId.equals(generatedSession.id))).write(
        ChatSessionsCompanion(
          messagesJson: Value(messagesJson),
          sessionVarsJson: Value(sessionVarsJson),
          authorsNoteJson: Value(authorsNoteJson),
          draft: Value(updated.draft),
          lastScrollAnchorJson: Value(lastScrollAnchorJson),
          updatedAt: Value(generatedSession.updatedAt),
        ),
      );

      if (manifest != null) {
        // A durable round trip verifies all strict schema/content/hash
        // invariants before any provenance row can be written.
        final durable = ExactLorebookManifest.decodeDurable(manifest.toJson());
        await LorebookUseManifestRepo(_db).insertGenerationManifest(
          identity: LorebookUseGenerationIdentity(
            sessionId: updated.id,
            messageId: committed.id,
            swipeId: committed.swipeId,
            agentSwipeId: committed.agentSwipeId,
          ),
          manifest: LorebookUseManifestInput(
            manifestJson: durable.canonicalJson,
            manifestHash: durable.canonicalHash,
            manifestSchemaVersion: 1,
            finalPromptHash: durable.providerMessagesHash,
            presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
          ),
          createdAt: generatedSession.updatedAt,
          entries: [
            for (var index = 0; index < durable.entries.length; index++)
              LorebookUseManifestEntryInput(
                lorebookId: durable.entries[index].lorebookId,
                entryId: durable.entries[index].entryId,
                entryOrder: index,
                evidenceJson: jsonEncode(durable.entries[index].toJson()),
              ),
          ],
        );
      }

      return updated.copyWith(updatedAt: generatedSession.updatedAt);
    });
  }

  static bool _sameGenerationAnchor(ChatMessage expected, ChatMessage current) {
    return expected.content == current.content &&
        expected.swipeId == current.swipeId &&
        expected.agentSwipeId == current.agentSwipeId &&
        jsonEncode(expected.swipes) == jsonEncode(current.swipes) &&
        jsonEncode(expected.swipesMeta) == jsonEncode(current.swipesMeta) &&
        jsonEncode(
              expected.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            ) ==
            jsonEncode(
              current.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            );
  }

  /// Ids of the sessions whose variables JSON contains [text].
  Future<List<String>> sessionIdsWithVarsContaining(String text) async {
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([_db.chatSessions.sessionId])
      ..where(_db.chatSessions.sessionVarsJson.contains(text));
    return [
      for (final row in await query.get())
        row.read(_db.chatSessions.sessionId)!,
    ];
  }

  Future<Map<String, dynamic>> updateSessionVarsJson(
    String sessionId,
    Map<String, dynamic> Function(Map<String, dynamic> vars) update,
  ) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) {
        throw StateError('Chat session "$sessionId" was not found');
      }

      final current = _decodeJsonMap(row.sessionVarsJson);
      final updated = update(Map<String, dynamic>.from(current));
      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          sessionVarsJson: Value(
            updated.isNotEmpty ? jsonEncode(updated) : null,
          ),
        ),
      );
      return updated;
    });
  }

  static Map<String, String> applySessionVarDelta(
    Map<String, String> latest,
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final merged = Map<String, String>.from(latest);
    for (final key in before.keys) {
      if (!after.containsKey(key)) merged.remove(key);
    }
    for (final entry in after.entries) {
      if (before[entry.key] != entry.value) merged[entry.key] = entry.value;
    }
    return merged;
  }

  @override
  Future<void> delete(String sessionId) async {
    await (_db.delete(
      _db.chatSessions,
    )..where((t) => t.sessionId.equals(sessionId))).go();
  }

  /// Atomically updates a single message's content and appends a new swipe.
  ///
  /// Used by the POST-cleaner (Stage 4) to replace the assistant text while
  /// preserving the original as a swipe. Wraps the read-modify-write in a
  /// transaction so concurrent writes cannot interleave (database.md Rule 3).
  ///
  /// [messageId] — the message to update.
  /// [newContent] — the cleaned text that becomes the active content.
  /// [previousContent] — the original text, appended as the last swipe.
  /// Returns `true` if the message was found and updated.
  Future<bool> appendSwipeToMessage({
    required String sessionId,
    required String messageId,
    required String newContent,
    required String previousContent,
  }) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return false;

      final messages = await _decodeMessagesAsync(row.messagesJson);

      var found = false;
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i].id == messageId) {
          final msg = messages[i];
          final swipes = List<String>.from(msg.swipes);
          // Preserve original as previous swipe, add cleaned as new swipe.
          if (swipes.isNotEmpty) {
            swipes[swipes.length - 1] = previousContent;
          }
          swipes.add(newContent);
          messages[i] = msg.copyWith(
            content: newContent,
            swipes: swipes,
            swipeId: swipes.length - 1,
          );
          found = true;
          break;
        }
      }

      if (!found) return false;

      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          messagesJson: Value(await _encodeMessagesAsync(messages)),
        ),
      );
      return true;
    });
  }

  /// Atomically appends a new green swipe carrying [cleanedText] to a
  /// message, then sets that swipe as the active content. Used by the
  /// POST-cleaner (Stage 4) to preserve the original as the previous swipe
  /// and make the cleaned text the current one. Wraps the read-modify-write
  /// in a transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message was found and updated.
  Future<bool> appendCleanerSwipe({
    required String sessionId,
    required String messageId,
    required String cleanedText,
  }) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return false;

      final messages = await _decodeMessagesAsync(row.messagesJson);

      var found = false;
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i].id == messageId) {
          final msg = messages[i];
          final swipes = List<String>.from(msg.swipes);
          final swipesMeta = List<Map<String, dynamic>>.from(msg.swipesMeta);
          // Ensure swipes/swipesMeta are seeded from the current content if
          // the message predated the swipes model (single-content fallback).
          if (swipes.isEmpty) {
            swipes.add(msg.content);
          }
          while (swipesMeta.length < swipes.length) {
            swipesMeta.add(<String, dynamic>{});
          }
          // Append the cleaned text as a new green swipe.
          swipes.add(cleanedText);
          swipesMeta.add(<String, dynamic>{});
          final newSwipeId = swipes.length - 1;
          messages[i] = msg.copyWith(
            content: cleanedText,
            swipes: swipes,
            swipesMeta: swipesMeta,
            swipeId: newSwipeId,
          );
          found = true;
          break;
        }
      }

      if (!found) return false;

      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          messagesJson: Value(await _encodeMessagesAsync(messages)),
        ),
      );
      return true;
    });
  }

  /// Atomically appends a nested agent swipe ([kind]: 'cleaned' | 'final') to
  /// a message and sets it as the active agent swipe. Used by the POST-cleaner
  /// to write a blue 'cleaned' sub-swipe (preserving the original 'final' as
  /// the parent) and by Studio final-regen to write a new 'final' sub-swipe.
  ///
  /// Lazy-migrates a 'final' from the current content when the first 'cleaned'
  /// swipe is added to a message that predates the agentSwipes model. Inherits
  /// `studioOutputs` from the parent 'final' so the Studio regen button stays
  /// visible on the cleaned swipe. Wraps the read-modify-write in a
  /// transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message was found and updated.
  Future<bool> appendAgentSwipe({
    required String sessionId,
    required String messageId,
    required String content,
    required String kind,
    String? reasoning,
    String? genTime,
    int? tokens,
    List<Map<String, dynamic>> studioOutputs = const [],
  }) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return false;

      final messages = await _decodeMessagesAsync(row.messagesJson);

      var found = false;
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i].id == messageId) {
          final msg = messages[i];
          final agentSwipes = List<AgentSwipe>.from(msg.agentSwipes);

          // Lazy migration: if agentSwipes is empty and we're adding a
          // 'cleaned' swipe, backfill a 'final' from the current content.
          if (agentSwipes.isEmpty && kind == 'cleaned') {
            agentSwipes.add(
              AgentSwipe(
                content: msg.content,
                kind: 'final',
                reasoning: msg.reasoning,
                genTime: msg.genTime,
                tokens: msg.tokens,
                time: msg.time,
                studioOutputs: msg.studioOutputs,
              ),
            );
          }

          // A 'cleaned' swipe's parent is always the original 'final' swipe,
          // never a previous 'cleaned' swipe. This matters for Re-run cleaner:
          // each re-run must re-clean the original final text, not a previous
          // (already shortened) cleaned swipe. Find the last 'final' swipe in
          // the list (the lazy-migration block above backfills one at index 0
          // when needed). Fall back to the last swipe only if no 'final' is
          // present at all (defensive — should not happen in practice).
          var parentSwipeId = kind == 'cleaned' && agentSwipes.isNotEmpty
              ? agentSwipes.lastIndexWhere((s) => s.kind == 'final')
              : null;
          if (kind == 'cleaned' &&
              parentSwipeId == null &&
              agentSwipes.isNotEmpty) {
            parentSwipeId = agentSwipes.length - 1;
          }

          // Inherit studioOutputs from the parent 'final' swipe so that
          // switching to the 'cleaned' blue swipe keeps the Studio regen
          // button visible (showStudioFinalRegen depends on studioOutputs).
          final effectiveStudioOutputs = studioOutputs.isNotEmpty
              ? studioOutputs
              : (kind == 'cleaned' && parentSwipeId != null
                    ? agentSwipes[parentSwipeId].studioOutputs
                    : const <Map<String, dynamic>>[]);

          final appendedSwipe = AgentSwipe(
            content: content,
            kind: kind,
            reasoning: reasoning,
            genTime: genTime,
            tokens: tokens,
            time: kind == 'cleaned' && parentSwipeId != null
                ? agentSwipes[parentSwipeId].time
                : null,
            studioOutputs: effectiveStudioOutputs,
            parentSwipeId: parentSwipeId,
          );
          agentSwipes.add(appendedSwipe);

          messages[i] = msg.copyWith(
            content: content,
            // The new swipe becomes the active swipe — sync the top-level
            // rendered genTime/tokens so the chat bubble badge matches the
            // swipe (mirrors updateAgentSwipeContent's isActive branch).
            // Without this, appendAgentSwipe leaves the message's genTime/
            // tokens pointing at the previous (parent) swipe, so the badge
            // shows stale values or null after a cleaner finalize via the
            // applyCleanedText fallback path.
            genTime: genTime ?? msg.genTime,
            tokens: tokens ?? msg.tokens,
            time: appendedSwipe.time,
            agentSwipes: agentSwipes,
            agentSwipeId: agentSwipes.length - 1,
            swipesMeta: _syncAgentSwipesToMeta(
              msg.swipesMeta,
              msg.swipeId,
              agentSwipes,
              agentSwipes.length - 1,
            ),
          );
          found = true;
          break;
        }
      }

      if (!found) return false;

      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          messagesJson: Value(await _encodeMessagesAsync(messages)),
        ),
      );
      return true;
    });
  }

  /// Atomically updates the content (and optional genTime/tokens) of an
  /// existing nested agent swipe in place, without appending a new one.
  ///
  /// Used by the POST-cleaner swipe-first flow (Fix 1): a blue 'cleaned' swipe
  /// is pre-created at cleaner start, the rewrite streams into the chat bubble
  /// for live preview, and on completion this method fills the pre-created
  /// swipe with the final cleaned text + per-swipe badge metadata. On cleaner
  /// failure with partial text, the same method persists the truncated
  /// partial text.
  ///
  /// When [agentSwipeId] is the active swipe for the message, the top-level
  /// `content`/`genTime`/`tokens` are also updated so the chat list and the
  /// rendered bubble reflect the new text immediately.
  ///
  /// Wraps the read-modify-write in a transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message and swipe were found and updated.
  Future<bool> updateAgentSwipeContent({
    required String sessionId,
    required String messageId,
    required int agentSwipeId,
    required String content,
    String? genTime,
    int? tokens,
  }) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return false;

      final messages = await _decodeMessagesAsync(row.messagesJson);

      var found = false;
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i].id != messageId) continue;
        final msg = messages[i];
        if (agentSwipeId < 0 || agentSwipeId >= msg.agentSwipes.length) {
          return false;
        }
        final agentSwipes = List<AgentSwipe>.from(msg.agentSwipes);
        final prev = agentSwipes[agentSwipeId];
        agentSwipes[agentSwipeId] = prev.copyWith(
          content: content,
          genTime: genTime ?? prev.genTime,
          tokens: tokens ?? prev.tokens,
        );

        // When this is the active swipe, also update the top-level rendered
        // content so the chat list + bubble match the swipe (mirrors
        // appendAgentSwipe which writes `content: content` on the message).
        final isActive = msg.agentSwipeId == agentSwipeId;
        messages[i] = msg.copyWith(
          content: isActive ? content : msg.content,
          genTime: isActive ? (genTime ?? msg.genTime) : msg.genTime,
          tokens: isActive ? (tokens ?? msg.tokens) : msg.tokens,
          agentSwipes: agentSwipes,
          swipesMeta: _syncAgentSwipesToMeta(
            msg.swipesMeta,
            msg.swipeId,
            agentSwipes,
            msg.agentSwipeId,
          ),
        );
        found = true;
        break;
      }

      if (!found) return false;

      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          messagesJson: Value(await _encodeMessagesAsync(messages)),
        ),
      );
      return true;
    });
  }

  /// Atomically removes a nested agent swipe and resets the active swipe to
  /// the last remaining one (typically the parent 'final'). Used by the
  /// POST-cleaner swipe-first flow (Fix 1) when the cleaner wrote nothing at
  /// all on failure — the pre-created empty 'cleaned' swipe is deleted and the
  /// UI reverts to the original 'final' text.
  ///
  /// After removal, the active [agentSwipeId] is clamped to the last remaining
  /// swipe, and the top-level `content`/`genTime`/`tokens` are restored from
  /// that swipe so the bubble shows the original text. Does NOT remove the
  /// last remaining swipe (preserves the parent 'final').
  ///
  /// Wraps the read-modify-write in a transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message and swipe were found and removed.
  Future<bool> removeAgentSwipe({
    required String sessionId,
    required String messageId,
    required int agentSwipeId,
  }) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return false;

      final messages = await _decodeMessagesAsync(row.messagesJson);

      var found = false;
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i].id != messageId) continue;
        final msg = messages[i];
        if (agentSwipeId < 0 || agentSwipeId >= msg.agentSwipes.length) {
          return false;
        }
        // Never remove the last remaining swipe — preserve the parent 'final'.
        if (msg.agentSwipes.length <= 1) return false;

        final agentSwipes = List<AgentSwipe>.from(msg.agentSwipes)
          ..removeAt(agentSwipeId);
        // Clamp active to the last remaining swipe (parent 'final' when the
        // caller removed a 'cleaned' sub-swipe).
        final newActiveId = (msg.agentSwipeId >= agentSwipes.length)
            ? agentSwipes.length - 1
            : (msg.agentSwipeId > agentSwipeId
                  ? msg.agentSwipeId - 1
                  : msg.agentSwipeId);
        final active = agentSwipes[newActiveId];

        messages[i] = msg.copyWith(
          content: active.content,
          genTime: active.genTime,
          tokens: active.tokens,
          time: active.time,
          agentSwipes: agentSwipes,
          agentSwipeId: newActiveId,
          swipesMeta: _syncAgentSwipesToMeta(
            msg.swipesMeta,
            msg.swipeId,
            agentSwipes,
            newActiveId,
          ),
        );
        found = true;
        break;
      }

      if (!found) return false;

      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          messagesJson: Value(await _encodeMessagesAsync(messages)),
        ),
      );
      return true;
    });
  }

  /// Sync [agentSwipes] + [agentSwipeId] into `swipesMeta[swipeId]` so that
  /// green-swipe round-trips preserve agent swipes even without an explicit
  /// `setSwipe` navigation-away. This eliminates the dual-storage mismatch
  /// where `appendAgentSwipe` wrote only the top-level field.
  static List<Map<String, dynamic>> _syncAgentSwipesToMeta(
    List<Map<String, dynamic>> swipesMeta,
    int swipeId,
    List<AgentSwipe> agentSwipes,
    int agentSwipeId,
  ) {
    if (swipeId < 0) return swipesMeta;
    final meta = List<Map<String, dynamic>>.from(swipesMeta);
    while (meta.length <= swipeId) {
      meta.add(<String, dynamic>{});
    }
    meta[swipeId] = {
      ...meta[swipeId],
      'agentSwipes': agentSwipes.map((e) => e.toJson()).toList(),
      'agentSwipeId': agentSwipeId,
    };
    return meta;
  }

  /// Deletes all sessions belonging to [characterId], along with all per-session
  /// dependent data (memory books, summaries). Returns the deleted session IDs
  /// for sync-deletion tracking.
  Future<List<String>> deleteByCharacterId(String characterId) async {
    return _db.transaction(() async {
      final rows = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.characterId.equals(characterId))).get();
      final ids = rows.map((r) => r.sessionId).toList();
      final deletion = SessionDeletionQueries(_db);
      for (final id in ids) {
        await deletion.deleteSessionRows(id);
      }
      return ids;
    });
  }

  SessionMetadata _projectedMetadata(QueryRow row) {
    final lastMessageJson = row.readNullable<String>('last_message_json');
    var lastContent = '';
    var lastTimestamp = 0;
    if (lastMessageJson != null) {
      try {
        final lastMessage = jsonDecode(lastMessageJson) as Map<String, dynamic>;
        final rawContent = lastMessage['content'];
        if (rawContent is String) {
          lastContent = rawContent;
        } else if (rawContent is List) {
          lastContent = rawContent
              .whereType<Map<Object?, Object?>>()
              .where((part) => part['type'] == 'text' && part['text'] is String)
              .map((part) => part['text'] as String)
              .join(' ');
        }
        lastContent = previewSource(
          lastContent,
          lastMessage['continuationOffset'] as int?,
        );
        if (lastContent.length > 250) {
          lastContent = lastContent.substring(0, 250);
        }
        lastTimestamp = (lastMessage['timestamp'] as int?) ?? 0;
      } catch (_) {}
    }

    String? sessionName;
    int? branchedAt;
    final sessionVarsJson = row.readNullable<String>('session_vars_json');
    if (sessionVarsJson != null && sessionVarsJson.isNotEmpty) {
      try {
        final vars = jsonDecode(sessionVarsJson) as Map;
        sessionName = vars['sessionName'] as String?;
        final rawBranchedAt = vars['branchedAt'];
        if (rawBranchedAt is String) branchedAt = int.tryParse(rawBranchedAt);
      } catch (_) {}
    }

    final firstTimestamp = row.readNullable<int>('first_timestamp') ?? 0;
    final hasBranchTimestamp = branchedAt != null && branchedAt > 0;
    return SessionMetadata(
      sessionId: row.read<String>('session_id'),
      characterId: row.read<String>('character_id'),
      sessionIndex: row.read<int>('session_index'),
      updatedAt: row.read<int>('updated_at'),
      messageCount: row.readNullable<int>('message_count') ?? 0,
      lastMessageContent: lastContent,
      lastMessageTimestamp: lastTimestamp,
      sessionName: sessionName,
      originTimestamp: hasBranchTimestamp ? branchedAt : firstTimestamp,
      originKind: hasBranchTimestamp
          ? 'branched'
          : firstTimestamp > 0
          ? 'created'
          : null,
    );
  }

  ChatSession _toModel(ChatSessionRow c, {List<ChatMessage>? messages}) =>
      ChatSession(
        id: c.sessionId,
        characterId: c.characterId,
        sessionIndex: c.sessionIndex,
        messages: messages ?? _decodeMessages(c.messagesJson),
        updatedAt: c.updatedAt,
        sessionVars: c.sessionVarsJson != null
            ? Map<String, String>.from(jsonDecode(c.sessionVarsJson!) as Map)
            : {},
        authorsNote: _parseAuthorsNote(c.authorsNoteJson),
        draft: c.draft,
        lastScrollAnchor:
            c.lastScrollAnchorJson != null && c.lastScrollAnchorJson!.isNotEmpty
            ? Map<String, dynamic>.from(
                jsonDecode(c.lastScrollAnchorJson!) as Map,
              )
            : {},
      );

  /// [_toModel] with the blob decoded off this isolate when it is big.
  Future<ChatSession> _toModelAsync(ChatSessionRow c) async =>
      _toModel(c, messages: await _decodeMessagesAsync(c.messagesJson));

  /// A blob this long is decoded in another isolate. Below it, the decode is
  /// quicker than starting one.
  static const _offloadDecodeChars = 256 * 1024;

  /// Past this many messages, the blob is encoded a slice at a time with the
  /// event loop let through between slices, so frames keep coming.
  static const _chunkedEncodeMessages = 48;

  /// Messages per slice of a chunked encode: about a frame's worth of work on
  /// a long chat.
  static const _encodeSliceMessages = 16;

  /// The stored message list as models. Timed: a long chat is one JSON blob,
  /// and this is where opening it spends its time.
  static List<ChatMessage> _decodeMessages(String json) => PerfDebug.slowPhase(
    'decode chat (${PerfDebug.size(json.length)})',
    () => _decodeChatMessages(json),
  );

  /// [_decodeMessages], in another isolate when the blob is big: the 32 MB a
  /// long roleplay comes to takes a third of a second to decode, and that
  /// used to be a third of a second with no frames. The isolate hands the
  /// models back without copying them (`Isolate.run` exits with the result).
  static Future<List<ChatMessage>> _decodeMessagesAsync(String json) {
    if (json.length < _offloadDecodeChars) {
      return Future.value(_decodeMessages(json));
    }
    return PerfDebug.slowAwait(
      'decode chat off-thread (${PerfDebug.size(json.length)})',
      () => Isolate.run(() => _decodeChatMessages(json)),
    );
  }

  /// The models as the stored blob. Timed like [_decodeMessages]: every
  /// message mutation writes the whole chat back.
  static String _encodeMessages(List<ChatMessage> messages) =>
      PerfDebug.slowPhase(
        'encode chat (${messages.length} messages)',
        () => jsonEncode(messages.map((e) => e.toJson()).toList()),
      );

  /// [_encodeMessages] for a long chat, a slice at a time. Sending the
  /// models to another isolate would copy them all first, on this isolate;
  /// encoding them here in slices and yielding between slices keeps the UI
  /// painting instead. The slices join to the very bytes [jsonEncode] gives
  /// for the whole list: no whitespace, elements comma-separated.
  ///
  /// Inside a write transaction the yield keeps the transaction open across
  /// frames, and other database work queues behind it for as long as the
  /// encode takes — the same wait the whole-list encode imposed, only with
  /// frames let through in the meantime.
  static Future<String> _encodeMessagesAsync(List<ChatMessage> messages) async {
    if (messages.length <= _chunkedEncodeMessages) {
      return _encodeMessages(messages);
    }
    return PerfDebug.slowAwait('encode chat (${messages.length} messages) '
        'in slices', () async {
      final parts = <String>[];
      for (var i = 0; i < messages.length; i++) {
        parts.add(jsonEncode(messages[i].toJson()));
        if (i % _encodeSliceMessages == _encodeSliceMessages - 1) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      return '[${parts.join(',')}]';
    });
  }

  Future<ChatSessionsCompanion> _toCompanionAsync(ChatSession m) async =>
      _toCompanion(m, messagesJson: await _encodeMessagesAsync(m.messages));

  ChatSessionsCompanion _toCompanion(ChatSession m, {String? messagesJson}) =>
      ChatSessionsCompanion(
        sessionId: Value(m.id),
        characterId: Value(m.characterId),
        sessionIndex: Value(m.sessionIndex),
        messagesJson: Value(messagesJson ?? _encodeMessages(m.messages)),
        updatedAt: Value(m.updatedAt),
        sessionVarsJson: Value(
          m.sessionVars.isNotEmpty ? jsonEncode(m.sessionVars) : null,
        ),
        authorsNoteJson: Value(
          m.authorsNote != null ? jsonEncode(m.authorsNote!.toJson()) : null,
        ),
        draft: Value(m.draft),
        lastScrollAnchorJson: Value(
          m.lastScrollAnchor.isNotEmpty ? jsonEncode(m.lastScrollAnchor) : null,
        ),
      );

  AuthorsNote? _parseAuthorsNote(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is String) {
        return AuthorsNote(content: decoded);
      }
      if (decoded is Map<String, dynamic>) {
        return AuthorsNote.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic> _decodeJsonMap(String? text) {
    if (text == null || text.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return <String, dynamic>{};
  }
}

/// Decoding and encoding a long chat history is CPU-bound. Keep it out of the
/// UI isolate. Callers do this before opening a short compare-and-swap
/// transaction so an isolate delay cannot occupy the database executor.
Future<_PreparedUserMessageAppend> _prepareUserMessageAppend(
  String messagesJson,
  ChatMessage message,
) => Isolate.run(
  () => _decodeAndAppendUserMessage(messagesJson, message.toJson()),
);

Future<_PreparedUserMessageAppend?> _prepareAcceptedUserMessageAppend({
  required String messagesJson,
  required ChatMessage message,
  required LorebookUseGenerationIdentity expectedPrecedingAssistant,
}) => Isolate.run(
  () => _decodeAndAppendAcceptedUserMessage(
    messagesJson,
    message.toJson(),
    expectedPrecedingAssistant.messageId,
    expectedPrecedingAssistant.swipeId,
    expectedPrecedingAssistant.agentSwipeId,
  ),
);

_PreparedUserMessageAppend _decodeAndAppendUserMessage(
  String messagesJson,
  Map<String, dynamic> messageJson,
) {
  final messages = _decodeChatMessages(messagesJson)
    ..add(ChatMessage.fromJson(messageJson));
  return _PreparedUserMessageAppend(
    messagesJson: jsonEncode(
      messages.map((message) => message.toJson()).toList(),
    ),
    messages: messages,
  );
}

_PreparedUserMessageAppend? _decodeAndAppendAcceptedUserMessage(
  String messagesJson,
  Map<String, dynamic> messageJson,
  String expectedMessageId,
  int expectedSwipeId,
  int expectedAgentSwipeId,
) {
  final messages = _decodeChatMessages(messagesJson);
  final message = ChatMessage.fromJson(messageJson);
  if (messages.any((existing) => existing.id == message.id)) {
    return _PreparedUserMessageAppend(
      messagesJson: messagesJson,
      messages: messages,
      didAppend: false,
    );
  }

  // A user send accepts only the assistant immediately before it, never an
  // older assistant found by scanning history after a concurrent change.
  final preceding = messages.isNotEmpty ? messages.last : null;
  if (preceding == null ||
      preceding.role != 'assistant' ||
      preceding.id != expectedMessageId ||
      preceding.swipeId != expectedSwipeId ||
      preceding.agentSwipeId != expectedAgentSwipeId) {
    return null;
  }

  messages.add(message);
  return _PreparedUserMessageAppend(
    messagesJson: jsonEncode(messages.map((item) => item.toJson()).toList()),
    messages: messages,
  );
}

List<ChatMessage> _decodeChatMessages(String messagesJson) =>
    (jsonDecode(messagesJson) as List<dynamic>)
        .map((entry) => ChatMessage.fromJson(entry as Map<String, dynamic>))
        .toList();
