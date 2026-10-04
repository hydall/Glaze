// The Regenerate button under a trailing user message is drawn by the WebView
// renderer straight from the message map (`showRegen` in message_renderer.js),
// not only by the imperative `setLastMessage` path. So the map is where the
// send window has to be visible: a message whose reply is already on its way
// must not be offered as a re-roll.

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';

void main() {
  ChatMessage user() =>
      const ChatMessage(id: 'u1', role: 'user', content: 'привет');

  test('a just-sent user message is flagged as pending, not idle', () {
    final map = ChatMessageMapper.toMap(
      user(),
      const ChatMessageMapperContext(isGenerating: false, isSendPending: true),
      isLast: true,
    );

    expect(map['isLast'], isTrue);
    // Nothing is streaming yet — the flag the renderer needs is this one.
    expect(map['isGenerating'], isFalse);
    expect(map['isSendPending'], isTrue);
  });

  test('an idle trailing user message carries no pending flag', () {
    final map = ChatMessageMapper.toMap(
      user(),
      const ChatMessageMapperContext(isGenerating: false),
      isLast: true,
    );

    expect(map['isLast'], isTrue);
    expect(map.containsKey('isSendPending'), isFalse);
  });
}
