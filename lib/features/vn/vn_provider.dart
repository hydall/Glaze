import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repositories/chat_repo.dart';
import '../../core/models/chat_message.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/id_generator.dart';
import '../chat/generating_sessions_provider.dart';
import 'models/vn_document.dart';
import 'services/vn_generator_service.dart';

/// One novel: its session, the passes read back from it, and the pass being
/// written, if any.
@immutable
class VnState {
  const VnState({
    required this.session,
    required this.doc,
    this.writing,
    this.error,
  });

  final ChatSession session;
  final VnDocument doc;

  /// The pass the player is waiting on.
  final VnPass? writing;

  /// Why the last pass failed; cleared when the next one starts.
  final Object? error;

  VnPlayState? get play => VnPlayState.fromSessionVars(session.sessionVars);

  VnPersona? get persona => VnPersona.fromSessionVars(session.sessionVars);

  VnState copyWith({
    ChatSession? session,
    VnPass? writing,
    bool clearWriting = false,
    Object? error,
    bool clearError = false,
  }) {
    final next = session ?? this.session;
    return VnState(
      session: next,
      doc: session == null ? doc : VnDocument.fromMessages(next.messages),
      writing: clearWriting ? null : (writing ?? this.writing),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Starts a novel from [premise], played as [persona], and returns its
/// session id. The passes are written by [VnNotifier.writeSetup].
Future<String> createVnSession(
  ChatRepo repo,
  String premise, {
  VnPersona? persona,
  String? personaId,
}) async {
  final ids = newVnIds();
  final now = DateTime.now().millisecondsSinceEpoch;
  await repo.put(
    ChatSession(
      id: ids.sessionId,
      characterId: ids.characterId,
      sessionIndex: 0,
      updatedAt: now ~/ 1000,
      sessionVars: {
        if (persona != null) kVnPersonaVarKey: jsonEncode(persona.toJson()),
      },
      messages: [
        ChatMessage(
          id: generateId(),
          role: 'user',
          content: premise.trim(),
          timestamp: now,
          personaId: personaId,
          personaName: persona?.name,
        ),
      ],
    ),
  );
  return ids.sessionId;
}

/// A chapter being written ahead of the player.
class _Ahead {
  _Ahead(this.chapter, this.key, this.future, this.token);

  final int chapter;
  final String key;
  final Future<String> future;
  final CancelToken token;
}

/// Kept alive on purpose: a pass keeps being written after the screen is
/// left, and the chat list shows it as generating meanwhile.
final vnProvider = AsyncNotifierProvider.family<VnNotifier, VnState, String>(
  VnNotifier.new,
);

class VnNotifier extends AsyncNotifier<VnState> {
  VnNotifier(this.sessionId);

  final String sessionId;

  /// At most this many chapters are written ahead per chapter: each choice
  /// made near the end of a part makes the last one stale.
  static const int _maxAheadPerChapter = 3;

  _Ahead? _ahead;
  final Map<int, int> _aheadCount = {};

  @override
  Future<VnState> build() async {
    ref.onDispose(() => _ahead?.token.cancel('novel disposed'));
    final session = await ref.read(chatRepoProvider).getById(sessionId);
    if (session == null) throw StateError('Novel $sessionId is gone');
    return VnState(
      session: session,
      doc: VnDocument.fromMessages(session.messages),
    );
  }

  bool get _busy => state.value?.writing != null;

  /// Writes every pass the novel still lacks before it can be played: the
  /// scenario, characters, locations, textures, then the first chapter. A
  /// failure stops the run and is kept on [VnState.error]; calling again
  /// resumes from the pass that failed.
  Future<void> writeSetup({required String language}) async {
    if (_busy) return;
    while (true) {
      final current = state.value;
      final pass = current?.doc.pendingPass;
      if (current == null || pass == null) return;
      final ok = await _commit(
        pass,
        () => ref
            .read(vnGeneratorServiceProvider)
            .writePass(
              doc: current.doc,
              pass: pass,
              language: language,
              persona: current.persona,
            ),
      );
      if (!ok) return;
    }
  }

  /// Starts writing the next chapter before the player reaches its `next`.
  /// [snapshot] carries the scene's `exits`. Nothing is shown and nothing is
  /// committed: the chapter is banked until [continueStory] claims it.
  Future<void> writeAhead({
    required String language,
    required Map<String, dynamic> snapshot,
  }) async {
    final current = state.value;
    if (current == null || !current.doc.playable || _busy) return;
    final play = VnPlayState(snapshot);
    final chapter = current.doc.nextChapterNumber;
    final key = vnPrefetchKey(play);
    final banked = _banked(current);
    if (banked?.chapter == chapter && banked?.key == key) return;
    final ahead = _ahead;
    if (ahead != null && ahead.chapter == chapter && ahead.key == key) return;
    if ((_aheadCount[chapter] ?? 0) >= _maxAheadPerChapter) return;
    _aheadCount[chapter] = (_aheadCount[chapter] ?? 0) + 1;

    ahead?.token.cancel('stale chapter written ahead');
    final token = CancelToken();
    final future = ref
        .read(vnGeneratorServiceProvider)
        .writePass(
          doc: current.doc,
          pass: VnPass.chapter,
          language: language,
          state: play,
          persona: current.persona,
          cancelToken: token,
        );
    final mine = _Ahead(chapter, key, future, token);
    _ahead = mine;
    try {
      final body = await future;
      if (_ahead != mine) return;
      await _mutate(
        (s) => s.copyWith(
          sessionVars: {
            ...s.sessionVars,
            kVnPrefetchVarKey: jsonEncode({
              'chapter': chapter,
              'key': key,
              'body': body,
            }),
          },
        ),
        bumpActivity: false,
      );
    } catch (e) {
      debugPrint('[VN3D] chapter $chapter written ahead failed: $e');
    } finally {
      if (_ahead == mine) _ahead = null;
    }
  }

  /// Adds the next chapter from where the engine stopped. [snapshot] is the
  /// engine's state at its `next`. A chapter written ahead from the same
  /// flags, inventory and choices is used as is; otherwise one is written
  /// now. Returns whether a chapter was added.
  Future<bool> continueStory({
    required String language,
    required Map<String, dynamic> snapshot,
  }) async {
    if (_busy) return false;
    await saveState(snapshot);
    final current = state.value;
    if (current == null) return false;
    final play = VnPlayState(snapshot);
    final chapter = current.doc.nextChapterNumber;
    final key = vnPrefetchKey(play);

    final banked = _banked(current);
    if (banked != null && banked.chapter == chapter && banked.key == key) {
      return _commit(VnPass.chapter, () async => banked.body);
    }
    final ahead = _ahead;
    if (ahead != null && ahead.chapter == chapter && ahead.key == key) {
      return _commit(VnPass.chapter, () => ahead.future);
    }
    ahead?.token.cancel('the game moved past the chapter written ahead');
    _ahead = null;
    return _commit(
      VnPass.chapter,
      () => ref
          .read(vnGeneratorServiceProvider)
          .writePass(
            doc: current.doc,
            pass: VnPass.chapter,
            language: language,
            state: play,
            persona: current.persona,
          ),
    );
  }

  ({int chapter, String key, String body})? _banked(VnState s) {
    final json = s.session.sessionVars[kVnPrefetchVarKey];
    if (json == null) return null;
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      return (
        chapter: (m['chapter'] as num).toInt(),
        key: m['key'] as String,
        body: m['body'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// Runs [write] for [pass] with the player waiting on it, and appends what
  /// it returns as the next message. A committed chapter retires whatever
  /// was banked ahead.
  Future<bool> _commit(VnPass pass, Future<String> Function() write) async {
    final current = state.value;
    if (current == null) return false;
    state = AsyncData(current.copyWith(writing: pass, clearError: true));
    final generating = ref.read(generatingSessionsProvider.notifier)
      ..mark(sessionId);
    try {
      final body = await write();
      final now = DateTime.now().millisecondsSinceEpoch;
      final message = ChatMessage(
        id: generateId(),
        role: 'assistant',
        content: formatVnPass(
          pass,
          body,
          chapter: current.doc.nextChapterNumber,
        ),
        timestamp: now,
      );
      await _mutate((s) {
        final messages = [...s.messages, message];
        final vars = {...s.sessionVars};
        final title = VnDocument.fromMessages(messages).title;
        if (title != null && (vars['sessionName'] ?? '').isEmpty) {
          vars['sessionName'] = title;
        }
        if (pass == VnPass.chapter) vars.remove(kVnPrefetchVarKey);
        return s.copyWith(messages: messages, sessionVars: vars);
      });
      state = AsyncData(state.value!.copyWith(clearWriting: true));
      return true;
    } catch (e) {
      debugPrint('[VN3D] $pass failed: $e');
      state = AsyncData(
        (state.value ?? current).copyWith(clearWriting: true, error: e),
      );
      return false;
    } finally {
      generating.unmark(sessionId);
    }
  }

  /// Writes [mutate] to the session and keeps [state] on the result.
  Future<void> _mutate(
    ChatSession Function(ChatSession s) mutate, {
    bool bumpActivity = true,
  }) async {
    final updated = await ref
        .read(chatRepoProvider)
        .mutateSession(
          sessionId: sessionId,
          updatedAt: bumpActivity
              ? DateTime.now().millisecondsSinceEpoch ~/ 1000
              : null,
          mutate: mutate,
        );
    if (updated == null) throw StateError('Novel $sessionId is gone');
    final current = state.value;
    if (current == null) return;
    final messagesChanged =
        updated.messages.length != current.session.messages.length;
    state = AsyncData(
      messagesChanged
          ? current.copyWith(session: updated)
          : VnState(
              session: updated,
              doc: current.doc,
              writing: current.writing,
              error: current.error,
            ),
    );
  }

  /// Keeps the engine's [snapshot] on the session, so the novel reopens where
  /// it was left.
  Future<void> saveState(Map<String, dynamic> snapshot) async {
    final encoded = jsonEncode(snapshot);
    if (state.value?.session.sessionVars[kVnStateVarKey] == encoded) return;
    try {
      await _mutate(
        (s) => s.copyWith(
          sessionVars: {...s.sessionVars, kVnStateVarKey: encoded},
        ),
      );
    } catch (e) {
      debugPrint('[VN3D] saving the place failed: $e');
    }
  }
}
