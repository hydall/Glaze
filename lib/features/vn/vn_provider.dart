import 'dart:convert';

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

  /// The pass a request is out for.
  final VnPass? writing;

  /// Why the last pass failed; cleared when the next one starts.
  final Object? error;

  VnPlayState? get play => VnPlayState.fromSessionVars(session.sessionVars);

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

/// Starts a novel from [premise] and returns its session id. The passes are
/// written by [VnNotifier.writeSetup].
Future<String> createVnSession(ChatRepo repo, String premise) async {
  final ids = newVnIds();
  final now = DateTime.now().millisecondsSinceEpoch;
  await repo.put(
    ChatSession(
      id: ids.sessionId,
      characterId: ids.characterId,
      sessionIndex: 0,
      updatedAt: now ~/ 1000,
      messages: [
        ChatMessage(
          id: generateId(),
          role: 'user',
          content: premise.trim(),
          timestamp: now,
        ),
      ],
    ),
  );
  return ids.sessionId;
}

/// Kept alive on purpose: a pass keeps being written after the screen is
/// left, and the chat list shows it as generating meanwhile.
final vnProvider = AsyncNotifierProvider.family<VnNotifier, VnState, String>(
  VnNotifier.new,
);

class VnNotifier extends AsyncNotifier<VnState> {
  VnNotifier(this.sessionId);

  final String sessionId;

  @override
  Future<VnState> build() async {
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
      final pass = state.value?.doc.pendingPass;
      if (pass == null) return;
      if (!await _write(pass, language: language)) return;
    }
  }

  /// Writes the next chapter from where the engine stopped. [snapshot] is the
  /// engine's state at its `next`. Returns whether a chapter was added.
  Future<bool> continueStory({
    required String language,
    required Map<String, dynamic> snapshot,
  }) async {
    if (_busy) return false;
    await saveState(snapshot);
    return _write(
      VnPass.chapter,
      language: language,
      play: VnPlayState(snapshot),
    );
  }

  Future<bool> _write(
    VnPass pass, {
    required String language,
    VnPlayState? play,
  }) async {
    final current = state.value;
    if (current == null) return false;
    state = AsyncData(current.copyWith(writing: pass, clearError: true));
    final generating = ref.read(generatingSessionsProvider.notifier)
      ..mark(sessionId);
    try {
      final body = await ref
          .read(vnGeneratorServiceProvider)
          .writePass(
            doc: current.doc,
            pass: pass,
            language: language,
            state: play,
          );
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
      final updated = await ref
          .read(chatRepoProvider)
          .mutateSession(
            sessionId: sessionId,
            updatedAt: now ~/ 1000,
            mutate: (s) {
              final messages = [...s.messages, message];
              final vars = {...s.sessionVars};
              final title = VnDocument.fromMessages(messages).title;
              if (title != null && (vars['sessionName'] ?? '').isEmpty) {
                vars['sessionName'] = title;
              }
              return s.copyWith(messages: messages, sessionVars: vars);
            },
          );
      if (updated == null) throw StateError('Novel $sessionId is gone');
      state = AsyncData(
        (state.value ?? current).copyWith(session: updated, clearWriting: true),
      );
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

  /// Keeps the engine's [snapshot] on the session, so the novel reopens where
  /// it was left.
  Future<void> saveState(Map<String, dynamic> snapshot) async {
    final encoded = jsonEncode(snapshot);
    if (state.value?.session.sessionVars[kVnStateVarKey] == encoded) return;
    final updated = await ref
        .read(chatRepoProvider)
        .mutateSession(
          sessionId: sessionId,
          updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          mutate: (s) => s.copyWith(
            sessionVars: {...s.sessionVars, kVnStateVarKey: encoded},
          ),
        );
    final current = state.value;
    if (updated == null || current == null) return;
    state = AsyncData(
      VnState(
        session: updated,
        doc: current.doc,
        writing: current.writing,
        error: current.error,
      ),
    );
  }
}
