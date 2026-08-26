import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/auxiliary_timed_history.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  test('adds a Studio Ledger stamp for auxiliary consumers', () {
    const message = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'She waits.',
      time: '12.05.2027 · RP_Day 2 · 14:15',
    );

    expect(
      auxiliaryTimedContent(message),
      '[12.05.2027 · RP_Day 2 · 14:15] She waits.',
    );
  });

  test('ordinary messages remain unchanged when Ledger time is absent', () {
    const message = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'She waits.',
    );

    expect(auxiliaryTimedContent(message), 'She waits.');
  });
}
