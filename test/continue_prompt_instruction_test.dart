import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/services/preset_defaults.dart';

PromptMessage _history(String role, String content) =>
    PromptMessage(role: role, content: content, isHistory: true);

PromptMessage _depth(String content, int depth) => PromptMessage(
  role: 'system',
  content: content,
  depth: depth,
  isDepth: true,
);

void main() {
  group('insertContinueInstruction', () {
    test('lands immediately after the assistant reply being extended', () {
      final assembled = [
        _history('user', 'Hi'),
        _history('assistant', 'A partial reply'),
      ];

      final result = insertContinueInstruction(assembled, kContinueInstruction);

      expect(result.map((m) => m.content), [
        'Hi',
        'A partial reply',
        'Expand your latest message, continue.',
      ]);
      expect(result.last.role, 'system');
      expect(result.last.blockId, 'continue_instruction');
    });

    test('stays ahead of depth-0 blocks pinned to the end of history', () {
      // Depth-0 preset injections sit after the last history message. The
      // continue instruction must still be the turn *directly* after the reply,
      // otherwise the model reads "extend the message above" pointing at a
      // preset block instead of the assistant text.
      final assembled = [
        _history('assistant', 'A partial reply'),
        _depth('Author note', 0),
      ];

      final result = insertContinueInstruction(assembled, kContinueInstruction);

      expect(result.map((m) => m.content), [
        'A partial reply',
        'Expand your latest message, continue.',
        'Author note',
      ]);
    });

    test('is a no-op on every non-continue path', () {
      final assembled = [_history('assistant', 'A partial reply')];

      expect(
        identical(insertContinueInstruction(assembled, null), assembled),
        isTrue,
      );
      expect(
        identical(insertContinueInstruction(assembled, '   '), assembled),
        isTrue,
      );
    });

    test('is a no-op when the window carries no history message', () {
      final assembled = [_depth('Author note', 0)];

      expect(
        identical(
          insertContinueInstruction(assembled, kContinueInstruction),
          assembled,
        ),
        isTrue,
      );
    });
  });
}
