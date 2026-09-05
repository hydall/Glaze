import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/features/chat/widgets/prompt_preview_screen.dart';

void main() {
  const png =
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
      'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

  testWidgets('formatted preview renders a local image thumbnail', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PromptAttachmentPreview(imagePath: png)),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('prompt-attachment-image')), findsOne);
    expect(
      find.byKey(const ValueKey('prompt-attachment-unavailable')),
      findsNothing,
    );
  });

  testWidgets('malformed and remote images use a safe fallback', (
    tester,
  ) async {
    for (final path in [
      'data:image/png;base64,not-valid!',
      'https://x.test/a',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PromptAttachmentPreview(imagePath: path)),
        ),
      );

      expect(
        find.byKey(const ValueKey('prompt-attachment-unavailable')),
        findsOne,
      );
      expect(find.byType(Image), findsNothing);
    }
  });

  testWidgets('formatted message content renders markdown images', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PromptMarkdownPreview(
            content: 'Before ![portrait](https://example.com/a.png) after',
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('prompt-markdown-image')), findsOne);
  });

  testWidgets('formatted message rejects unsafe image schemes', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PromptMarkdownPreview(content: '![x](file:///private/a.png)'),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('prompt-markdown-image-unavailable')),
      findsOne,
    );
  });

  test('preview request retains image-only messages and exact data URI', () {
    final messages = buildPreviewApiMessages(const [
      PromptMessage(role: 'user', content: '', imagePaths: [png]),
    ]);

    expect(messages, [
      {
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': png},
          },
        ],
      },
    ]);
  });

  test('preview request includes only the nearest assistant reasoning', () {
    final messages = buildPreviewApiMessages(const [
      PromptMessage(
        role: 'assistant',
        content: 'first',
        reasoningContent: 'old reasoning',
      ),
      PromptMessage(role: 'user', content: 'next'),
      PromptMessage(
        role: 'assistant',
        content: 'second',
        reasoningContent: '  latest reasoning  ',
      ),
    ], reasoningHistoryCount: 1);

    expect(messages[0], isNot(contains('reasoning_content')));
    expect(messages[2]['reasoning_content'], 'latest reasoning');
  });

  test('preview request counts non-empty reasoning blocks', () {
    final messages = buildPreviewApiMessages(const [
      PromptMessage(
        role: 'assistant',
        content: 'first',
        reasoningContent: 'old reasoning',
      ),
      PromptMessage(role: 'assistant', content: 'second'),
    ], reasoningHistoryCount: 1);

    expect(messages[0]['reasoning_content'], 'old reasoning');
    expect(messages[1], isNot(contains('reasoning_content')));
  });

  test('preview request includes the requested number of reasoning blocks', () {
    final messages = buildPreviewApiMessages(const [
      PromptMessage(
        role: 'assistant',
        content: 'first',
        reasoningContent: 'first reasoning',
      ),
      PromptMessage(
        role: 'assistant',
        content: 'second',
        reasoningContent: 'second reasoning',
      ),
      PromptMessage(
        role: 'assistant',
        content: 'third',
        reasoningContent: 'third reasoning',
      ),
    ], reasoningHistoryCount: 2);

    expect(messages[0], isNot(contains('reasoning_content')));
    expect(messages[1]['reasoning_content'], 'second reasoning');
    expect(messages[2]['reasoning_content'], 'third reasoning');
  });

  test('minus one includes every reasoning block', () {
    final messages = buildPreviewApiMessages(const [
      PromptMessage(
        role: 'assistant',
        content: 'first',
        reasoningContent: 'first reasoning',
      ),
      PromptMessage(role: 'user', content: 'next'),
      PromptMessage(
        role: 'assistant',
        content: 'second',
        reasoningContent: 'second reasoning',
      ),
    ], reasoningHistoryCount: -1);

    expect(messages[0]['reasoning_content'], 'first reasoning');
    expect(messages[1], isNot(contains('reasoning_content')));
    expect(messages[2]['reasoning_content'], 'second reasoning');
  });

  test('zero reasoning history count omits every reasoning block', () {
    final messages = buildPreviewApiMessages(const [
      PromptMessage(
        role: 'assistant',
        content: 'reply',
        reasoningContent: 'hidden reasoning',
      ),
    ]);

    expect(messages.single, isNot(contains('reasoning_content')));
  });
}
