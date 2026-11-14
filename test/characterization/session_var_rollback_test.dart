import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';

/// Characterization test for INV-C5: session variables produced during
/// prompt assembly (via macros like {{setvar::x::42}}) must persist to
/// the database on the success path only. On any non-happy exit
/// (abort mid-stream, abort before stream, API error, top-level catch)
/// the pre-generation session vars must be preserved as-is.
///
/// The fix (PR-B C11) drops the `pendingSessionVars` write from
/// [SavedMessageWriter.writeError] and [SavedMessageWriter.writeRegenError].
/// This test exercises those two paths directly and asserts that the
/// returned [ChatState] keeps the original `session.sessionVars`.
void main() {
  const writer = SavedMessageWriter();

  ChatSession makeSession({
    Map<String, String> sessionVars = const {},
    List<ChatMessage> messages = const [],
  }) {
    return ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      messages: messages,
      sessionVars: sessionVars,
    );
  }

  group('INV-C5: session vars preserved on error paths', () {
    test('writeError: keeps original sessionVars (no pendingSessionVars write)',
        () {
      final session = makeSession(
        sessionVars: {'x': '1', 'y': '2'},
      );

      final result = writer.writeError(
        errorText: 'API timed out',
        currentSession: session,
      );

      // Original session vars must be preserved as-is.
      expect(result.session?.sessionVars, {'x': '1', 'y': '2'});
    });

    test('writeError: empty sessionVars stay empty', () {
      final session = makeSession();

      final result = writer.writeError(
        errorText: 'connection refused',
        currentSession: session,
      );

      expect(result.session?.sessionVars, isEmpty);
    });

    test('writeRegenError: keeps original sessionVars', () {
      final target = ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: 'original',
      );
      final session = makeSession(
        sessionVars: {'a': '1'},
        messages: [target],
      );

      final result = writer.writeRegenError(
        errorText: 'stream error',
        saveSession: session,
        regenTargetId: 'm1',
      );

      expect(result.session?.sessionVars, {'a': '1'});
    });

    test('writeRegenError: with missing regenTargetId falls back to writeError',
        () {
      final session = makeSession(sessionVars: {'k': 'v'});

      final result = writer.writeRegenError(
        errorText: 'no target found',
        saveSession: session,
        regenTargetId: 'does-not-exist',
      );

      expect(result.session?.sessionVars, {'k': 'v'});
    });
  });

  group('INV-C5: session vars persisted on success path', () {
    test('writeAssistant: writes pendingSessionVars when provided', () {
      final session = makeSession(sessionVars: {'old': '1'});

      final result = writer.writeAssistant(
        text: 'Hello',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
        pendingSessionVars: {'new': '2'},
      );

      // Success path: pending vars overwrite.
      expect(result.session?.sessionVars, {'new': '2'});
    });

    test('writeAssistant: keeps original vars when pendingSessionVars null',
        () {
      final session = makeSession(sessionVars: {'keep': '1'});

      final result = writer.writeAssistant(
        text: 'Hello',
        reasoning: null,
        currentSession: session,
        isAborted: () => false,
      );

      expect(result.session?.sessionVars, {'keep': '1'});
    });
  });
}
