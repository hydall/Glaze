import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/utils/message_preview.dart';

/// The notification body is built from the last message's text, truncated from
/// the front. A Continue run appends, so without the boundary the push that
/// announces a continuation quotes the half the user has already read
/// (INV-CM7).
void main() {
  test('the notification quotes the continuation, not the opening', () {
    const messages = [
      ChatMessage(id: 'u', role: 'user', content: 'go on'),
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'She set the lamp down.\n\nThen the door opened.',
        continuationOffset: 24,
      ),
    ];

    expect(buildMessagePreview(messages), 'Then the door opened.');
  });

  test('a message that was never continued is quoted from the start', () {
    const messages = [
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'She set the lamp down.',
      ),
    ];

    expect(buildMessagePreview(messages), 'She set the lamp down.');
  });

  test('markdown markers are still stripped out of a continuation', () {
    const messages = [
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'Opening.\n\n**Bold** and *soft* and ==red== text.',
        continuationOffset: 10,
      ),
    ];

    expect(buildMessagePreview(messages), 'and and text.');
  });

  test('the 80-character cap applies to the continuation slice', () {
    final tail = 'x' * 200;
    final messages = [
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'Opening.\n\n$tail',
        continuationOffset: 10,
      ),
    ];

    final preview = buildMessagePreview(messages)!;
    expect(preview, '${'x' * 80}...');
  });

  test('an empty continuation slice falls back to the whole message', () {
    const messages = [
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'Only an opening.\n\n',
        continuationOffset: 18,
      ),
    ];

    expect(buildMessagePreview(messages), 'Only an opening.');
  });
}
