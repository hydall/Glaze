import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/prompt/recalled_message_chunk.dart';
import 'package:glaze_flutter/core/llm/prompt/recalled_messages_resolver.dart';

void main() {
  const resolver = RecalledMessagesResolver();

  test('uses legacy content only when structured chunks are absent', () {
    expect(
      resolver.resolve(
        chunks: const [],
        visibleMessageIds: const {},
        fallbackContent: '<recalled>legacy</recalled>',
      ),
      allOf(
        contains('Historical evidence'),
        contains('Occurred: story time unknown'),
        endsWith('<recalled>legacy</recalled>'),
      ),
    );
    expect(
      resolver.resolve(
        chunks: const [
          RecalledMessageChunk(text: 'structured', messageIds: ['visible']),
        ],
        visibleMessageIds: const {'visible'},
        fallbackContent: '<recalled>legacy</recalled>',
      ),
      isNull,
    );
  });

  test('excludes a chunk when any source message is visible', () {
    final content = resolver.resolve(
      chunks: const [
        RecalledMessageChunk(
          text: 'overlapping',
          messageIds: ['hidden', 'visible'],
        ),
        RecalledMessageChunk(text: 'retained', messageIds: ['other']),
        RecalledMessageChunk(text: 'no provenance'),
      ],
      visibleMessageIds: const {'visible'},
    );

    expect(content, isNot(contains('overlapping')));
    expect(content, contains('retained'));
    expect(content, contains('no provenance'));
  });

  test('formats retained chunks with the canonical wrapper', () {
    final content = resolver.resolve(
      chunks: const [
        RecalledMessageChunk(text: '  first  '),
        RecalledMessageChunk(text: 'second'),
      ],
      visibleMessageIds: const {},
    );

    expect(
      content,
      allOf(
        startsWith(
          '<recalled_messages>\n[Historical evidence, not current state]',
        ),
        contains('Current story point: unknown'),
        contains('preserving speaker perspective'),
        endsWith(
          '---\nOccurred: story time unknown\nfirst\n---\nOccurred: story time unknown\nsecond\n</recalled_messages>',
        ),
        isNot(contains('ground truth context')),
      ),
    );
  });

  test('bypass retains chunks that overlap the source window', () {
    final content = resolver.resolve(
      chunks: const [
        RecalledMessageChunk(text: 'retained', messageIds: ['visible']),
      ],
      visibleMessageIds: const {'visible'},
      disableSourceWindowExclusion: true,
    );

    expect(content, contains('retained'));
  });

  test('blank structured chunks do not resurrect fallback content', () {
    final content = resolver.resolve(
      chunks: const [RecalledMessageChunk(text: '   ')],
      visibleMessageIds: const {},
      fallbackContent: '<recalled>legacy</recalled>',
    );

    expect(content, isNot(contains('legacy')));
  });
}
