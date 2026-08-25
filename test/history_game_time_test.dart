import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/fallback_prompt_builder.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/llm/prompt/prompt_payload.dart';

void main() {
  const macroCtx = MacroContext(
    charName: 'Alison',
    charId: 'character',
    sessionId: 'session',
  );

  test('history assembler prefixes ledger-stamped game time', () {
    final history = HistoryAssembler(macroCtx).assemble([
      const ChatMessage(id: 'u1', role: 'user', content: 'Hello'),
      const ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'She looks up.',
        time: '12.05.2027 · День 0 · 09:15',
      ),
    ]);

    expect(history[0].content, 'Hello');
    expect(history[1].content, '[12.05.2027 · День 0 · 09:15]\nShe looks up.');
  });

  test('history assembler leaves unstamped messages untouched', () {
    final history = HistoryAssembler(
      macroCtx,
    ).assemble([const ChatMessage(id: 'u1', role: 'user', content: 'Hello')]);

    expect(history[0].content, 'Hello');
  });

  test('fallback prompt builder carries the game time into history', () {
    final payload = PromptPayload(
      character: const Character(id: 'character', name: 'Alison'),
      history: const [
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'Hi.',
          time: 'День 2 · 18:30',
        ),
      ],
      apiConfig: const ApiConfig(id: 'api'),
      gameTime: '18:30',
    );

    final result = buildFallbackPrompt(payload);
    final historyMessage = result.messages.firstWhere(
      (m) => m.sourceMessageId == 'a1',
    );

    expect(historyMessage.content, '[День 2 · 18:30]\nHi.');
  });
}
