import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/inline_media.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';

void main() {
  final payload = 'iVBORw0KGgo${'A' * 4000}==';

  test('replaces inline base64 images with a placeholder', () {
    expect(
      stripInlineMedia(
        'Hi <img alt="x" src="data:image/png;base64,$payload"> there',
      ),
      'Hi [image] there',
    );
    expect(
      stripInlineMedia("<IMG SRC='data:image/jpeg;base64,$payload' />"),
      '[image]',
    );
    expect(
      stripInlineMedia('see data:audio/mpeg;base64,$payload end'),
      'see [audio] end',
    );
    expect(
      stripInlineMedia('![pic](data:image/webp;base64,$payload)'),
      '![pic]([image])',
    );
  });

  test('leaves ordinary text and short payloads alone', () {
    const tiny = '<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">';
    expect(stripInlineMedia(tiny), tiny);
    const url = '<img src="https://example.com/a.png">';
    expect(stripInlineMedia(url), url);
  });

  test('the request carries what the budget counted', () {
    final message = PromptMessage(
      role: 'assistant',
      content: 'Look: <img src="data:image/png;base64,$payload">',
    );
    final sent = message.toApiMap()['content'] as String;
    expect(sent, 'Look: [image]');
    expect(estimateTokens(message.content), estimateTokens(sent));
  });

  test('attachments still travel as image parts', () {
    final message = PromptMessage(
      role: 'user',
      content: 'data:image/png;base64,$payload',
      imagePaths: const ['/tmp/a.png'],
    );
    final parts = message.toApiMap()['content'] as List;
    expect(parts.first, {'type': 'text', 'text': '[image]'});
    expect(parts.last, {
      'type': 'image_url',
      'image_url': {'url': '/tmp/a.png'},
    });
  });
}
