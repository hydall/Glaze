// A user message stores the persona it was sent as (id and name) for the
// pipeline, but the chat renders every user message with the persona it speaks
// as now: switching persona re-faces the whole chat at once.

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';

void main() {
  const context = ChatMessageMapperContext(
    currentCharName: 'Alice',
    currentPersonaName: 'Nyx',
    isGenerating: false,
  );

  test('a message sent as another persona renders as the active one', () {
    const mara = ChatMessage(
      id: 'u1',
      role: 'user',
      content: 'привет',
      personaId: 'p-mara',
      personaName: 'Mara',
    );

    final map = ChatMessageMapper.toMap(mara, context);

    expect(map['displayName'], 'Nyx');
    // Nothing on the map may pin the message to its sender: the page follows
    // the active identity for every user message.
    expect(map.containsKey('personaId'), isFalse);
    expect(map.containsKey('personaName'), isFalse);
    expect(map.containsKey('avatarUrl'), isFalse);
    expect(map.containsKey('avatarFallback'), isFalse);
  });

  test('a message with no stored persona renders as the active one', () {
    const legacy = ChatMessage(id: 'u0', role: 'user', content: 'привет');

    final map = ChatMessageMapper.toMap(legacy, context);

    expect(map['displayName'], 'Nyx');
    expect(map.containsKey('personaName'), isFalse);
  });

  test('with no active persona a user message is "You"', () {
    const legacy = ChatMessage(id: 'u0', role: 'user', content: 'привет');

    final map = ChatMessageMapper.toMap(
      legacy,
      const ChatMessageMapperContext(isGenerating: false),
    );

    expect(map['displayName'], 'You');
  });

  test('an assistant message renders as the character', () {
    const reply = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'hi',
      personaId: 'p-mara',
      personaName: 'Mara',
    );

    final map = ChatMessageMapper.toMap(reply, context);

    expect(map['displayName'], 'Alice');
    expect(map.containsKey('personaId'), isFalse);
    expect(map.containsKey('avatarUrl'), isFalse);
  });
}
