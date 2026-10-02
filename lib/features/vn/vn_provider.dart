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
import 'services/vn_sprite_service.dart';

/// One novel: its session, the passes read back from it, and the pass being
/// written, if any.
@immutable
class VnState {
  const VnState({
    required this.session,
    required this.doc,
    this.writing,
    this.error,
    this.drawing,
    this.artError,
    this.artFailed = const {},
    this.drawingEmotion,
    this.artMissing = const {},
  });

  final ChatSession session;
  final VnDocument doc;

  /// The pass the player is waiting on.
  final VnPass? writing;

  /// Why the last pass failed; cleared when the next one starts.
  final Object? error;

  /// The cast id of the character whose sprites are being drawn.
  final String? drawing;

  /// Why drawing the cast stopped; cleared when it starts again.
  final Object? artError;

  /// Why a character could not be drawn, by cast id: the provider's error,
  /// or a [FormatException] for a picture that could not be cut.
  final Map<String, Object> artFailed;

  /// The one emotion of [drawing] being drawn again; null when the whole
  /// character is.
  final String? drawingEmotion;

  /// Why an emotion of a character came out without a picture, by cast id
  /// and emotion. Kept while the novel is open.
  final Map<String, Map<String, String>> artMissing;

  /// Whether the novel draws its cast with the image provider.
  bool get drawsCast => (session.sessionVars[kVnArtVarKey] ?? '').isNotEmpty;

  /// Whether the cast's sprites still wait for the player to accept them.
  /// A novel already played is past that.
  bool get awaitingCastReview =>
      drawsCast && session.sessionVars[kVnArtOkVarKey] != '1' && play == null;

  /// Whether the game can start: every pass written and the cast accepted.
  bool get ready => doc.playable && !awaitingCastReview;

  VnPlayState? get play => VnPlayState.fromSessionVars(session.sessionVars);

  VnPersona? get persona => VnPersona.fromSessionVars(session.sessionVars);

  VnState copyWith({
    ChatSession? session,
    VnPass? writing,
    bool clearWriting = false,
    Object? error,
    bool clearError = false,
    String? drawing,
    bool clearDrawing = false,
    Object? artError,
    bool clearArtError = false,
    Map<String, Object>? artFailed,
    String? drawingEmotion,
    Map<String, Map<String, String>>? artMissing,
  }) {
    final next = session ?? this.session;
    return VnState(
      session: next,
      doc: session == null ? doc : VnDocument.fromMessages(next.messages),
      writing: clearWriting ? null : (writing ?? this.writing),
      error: clearError ? null : (error ?? this.error),
      drawing: clearDrawing ? null : (drawing ?? this.drawing),
      artError: clearArtError ? null : (artError ?? this.artError),
      artFailed: artFailed ?? this.artFailed,
      drawingEmotion: clearDrawing
          ? null
          : (drawingEmotion ?? this.drawingEmotion),
      artMissing: artMissing ?? this.artMissing,
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
  String? artSize,
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
        kVnArtVarKey: ?artSize,
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

  bool _drawingCast = false;
  CancelToken? _artToken;
  // Characters the player asked to draw again.
  final Set<String> _redraw = {};
  // Single emotions the player asked to draw again, as (castId, emotion).
  final Set<(String, String)> _redrawEmotions = {};

  @override
  Future<VnState> build() async {
    ref.onDispose(() {
      _ahead?.token.cancel('novel disposed');
      _artToken?.cancel('novel disposed');
    });
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
      // The cast is drawn while the rest of the setup is written.
      if (pass == VnPass.characters) unawaited(drawCast());
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

  /// Draws sprites, one character at a time, for every cast member that has
  /// none and for those [redraw] asked for, when the novel was started with
  /// drawing on. Starts right after the characters pass; the player checks
  /// the result before the game starts, and later characters show as
  /// cardboard until theirs land. A provider error stops the run until
  /// [retryCast]; a picture that cannot be cut skips that character only.
  Future<void> drawCast() async {
    if (_drawingCast) return;
    _drawingCast = true;
    try {
      while (true) {
        final s = state.value;
        if (s == null) return;
        final size = s.session.sessionVars[kVnArtVarKey] ?? '';
        if (size.isEmpty || s.artError != null) return;
        final have = vnSpritesOf(s.session.sessionVars);
        final one = _redrawEmotions.firstOrNull;
        if (one != null) {
          _redrawEmotions.remove(one);
          final who = s.doc.cast[one.$1];
          if (who != null) await _drawEmotion(who, one.$2);
          continue;
        }
        final who = s.doc.cast.values
            .where(
              (c) =>
                  _redraw.contains(c.id) ||
                  (!have.containsKey(c.id) && !s.artFailed.containsKey(c.id)),
            )
            .firstOrNull;
        if (who == null) return;
        _redraw.remove(who.id);
        state = AsyncData(
          s.copyWith(
            drawing: who.id,
            artFailed: {...s.artFailed}..remove(who.id),
          ),
        );
        final token = _artToken = CancelToken();
        try {
          final drawn = await ref
              .read(vnSpriteServiceProvider)
              .draw(
                sessionId: sessionId,
                who: who,
                setting: vnSpriteSetting(s.doc),
                size: size,
                note: vnArtNotesOf(s.session.sessionVars)[who.id],
                cancelToken: token,
              );
          await _keepSprites(who.id, drawn.paths);
          final now = state.value;
          if (now != null) {
            state = AsyncData(
              now.copyWith(
                artMissing: {...now.artMissing, who.id: drawn.missing},
              ),
            );
          }
        } catch (e) {
          if (token.isCancelled) return;
          debugPrint('[VN3D] drawing ${who.id} failed: $e');
          final now = state.value;
          if (now == null) return;
          state = AsyncData(
            now.copyWith(
              artFailed: {...now.artFailed, who.id: e},
              // A picture that could not be cut costs one character; anything
              // else (no key, no quota, no network) would fail them all.
              artError: e is FormatException ? null : e,
            ),
          );
          if (e is! FormatException) return;
        }
      }
    } finally {
      _drawingCast = false;
      _artToken = null;
      final s = state.value;
      if (s != null && s.drawing != null) {
        state = AsyncData(s.copyWith(clearDrawing: true));
      }
    }
  }

  /// Draws [emotion] of [who] again; a failure is kept on
  /// [VnState.artMissing] and does not stop the run.
  Future<void> _drawEmotion(VnCastMember who, String emotion) async {
    final s = state.value;
    if (s == null) return;
    state = AsyncData(s.copyWith(drawing: who.id, drawingEmotion: emotion));
    final token = _artToken = CancelToken();
    String? reason;
    try {
      final paths = await ref
          .read(vnSpriteServiceProvider)
          .drawEmotion(
            sessionId: sessionId,
            who: who,
            emotion: emotion,
            current: vnSpritesOf(s.session.sessionVars)[who.id] ?? const {},
            cancelToken: token,
          );
      await _keepSprites(who.id, paths);
    } catch (e) {
      if (token.isCancelled) return;
      debugPrint('[VN3D] drawing ${who.id} $emotion failed: $e');
      reason = vnArtReason(e);
    }
    final now = state.value;
    if (now == null) return;
    final missing = {...?now.artMissing[who.id]};
    if (reason == null) {
      missing.remove(emotion);
    } else {
      missing[emotion] = reason;
    }
    state = AsyncData(
      now.copyWith(
        clearDrawing: true,
        artMissing: {...now.artMissing, who.id: missing},
      ),
    );
  }

  /// Puts [paths] on the session as [castId]'s sprites and deletes the files
  /// they replace.
  Future<void> _keepSprites(String castId, Map<String, String> paths) async {
    Map<String, String> old = const {};
    await _mutate((x) {
      final all = vnSpritesOf(x.sessionVars);
      old = all[castId] ?? const {};
      all[castId] = paths;
      return x.copyWith(
        sessionVars: {...x.sessionVars, kVnSpritesVarKey: jsonEncode(all)},
      );
    }, bumpActivity: false);
    final stale = old.values.toSet().difference(paths.values.toSet());
    if (stale.isNotEmpty) {
      await ref.read(vnSpriteServiceProvider).remove(stale);
    }
  }

  /// Draws one [emotion] of [castId] again, as an edit of their calm
  /// sprite; the rest of their set stays.
  Future<void> redrawEmotion(String castId, String emotion) async {
    _redrawEmotions.add((castId, emotion));
    final now = state.value;
    if (now != null && now.artError != null) {
      state = AsyncData(now.copyWith(clearArtError: true));
    }
    await drawCast();
  }

  /// Draws again every character that failed.
  Future<void> retryCast() async {
    final s = state.value;
    if (s != null) {
      state = AsyncData(s.copyWith(clearArtError: true, artFailed: const {}));
    }
    await drawCast();
  }

  /// Draws [castId] again, keeping [note] (what to change, empty for nothing)
  /// for this and later redraws. The old sprites stay until the new land.
  Future<void> redraw(String castId, String note) async {
    final s = state.value;
    if (s == null) return;
    final notes = vnArtNotesOf(s.session.sessionVars);
    if ((notes[castId] ?? '') != note) {
      if (note.isEmpty) {
        notes.remove(castId);
      } else {
        notes[castId] = note;
      }
      await _mutate(
        (x) => x.copyWith(
          sessionVars: {...x.sessionVars, kVnArtNotesVarKey: jsonEncode(notes)},
        ),
        bumpActivity: false,
      );
    }
    _redraw.add(castId);
    final now = state.value;
    if (now != null && now.artError != null) {
      state = AsyncData(now.copyWith(clearArtError: true));
    }
    await drawCast();
  }

  /// The player accepted the cast's sprites: the game may start.
  Future<void> approveCast() async {
    await _mutate(
      (x) => x.copyWith(sessionVars: {...x.sessionVars, kVnArtOkVarKey: '1'}),
      bumpActivity: false,
    );
  }

  /// Stops drawing: the sprites drawn so far stay, everyone else is
  /// cardboard.
  Future<void> skipArt() async {
    _artToken?.cancel('art skipped');
    _redraw.clear();
    _redrawEmotions.clear();
    await _mutate(
      (x) => x.copyWith(
        sessionVars: {...x.sessionVars, kVnArtOkVarKey: '1'}
          ..remove(kVnArtVarKey),
      ),
      bumpActivity: false,
    );
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
              drawing: current.drawing,
              artError: current.artError,
              artFailed: current.artFailed,
              drawingEmotion: current.drawingEmotion,
              artMissing: current.artMissing,
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
