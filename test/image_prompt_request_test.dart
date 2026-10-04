import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_regex_applicator.dart';
import 'package:glaze_flutter/core/llm/studio/studio_history_limiter.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  const image = 'data:image/png;base64,aW1hZ2U=';
  const second = 'data:image/jpeg;base64,c2Vjb25k';
  const third = 'data:image/png;base64,dGhpcmQ=';
  final assembler = HistoryAssembler(
    MacroContext(
      charName: 'Character',
      userName: 'User',
      charId: 'c1',
      sessionId: 's1',
    ),
  );

  test('history image becomes an OpenAI-compatible multimodal request', () {
    final prompt = assembler.assemble([
      const ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'What is this?',
        imagePath: image,
      ),
    ]).single;

    expect(prompt.sourceMessageId, 'm1');
    expect(prompt.imagePath, image);
    expect(prompt.toApiMap(), {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'What is this?'},
        {
          'type': 'image_url',
          'image_url': {'url': image},
        },
      ],
    });
  });

  test('every attachment becomes its own image_url part, in order', () {
    final prompt = assembler.assemble([
      const ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'What are these?',
        imagePath: image,
        extraImagePaths: [second, third],
      ),
    ]).single;

    expect(prompt.imagePaths, [image, second, third]);
    expect(prompt.toApiMap(), {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'What are these?'},
        {
          'type': 'image_url',
          'image_url': {'url': image},
        },
        {
          'type': 'image_url',
          'image_url': {'url': second},
        },
        {
          'type': 'image_url',
          'image_url': {'url': third},
        },
      ],
    });
  });

  test('attachments are sent to the model unless the eye hides them', () {
    final visible = assembler.assemble([
      const ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'What is this?',
        imagePath: image,
        extraImagePaths: [second],
      ),
    ]).single;
    final hidden = assembler.assemble([
      const ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'What is this?',
        imagePath: image,
        extraImagePaths: [second],
        imageHidden: true,
      ),
    ]).single;

    expect(visible.hasImage, isTrue);
    // The eye covers the whole message: one hidden flag, every attachment
    // dropped from the request.
    expect(hidden.hasImage, isFalse);
    expect(hidden.toApiMap(), {'role': 'user', 'content': 'What is this?'});
  });

  test('image-only message remains a valid multimodal request', () {
    const prompt = PromptMessage(
      role: 'user',
      content: '',
      imagePaths: [image],
    );

    expect(prompt.hasImage, isTrue);
    expect(prompt.toApiMap(), {
      'role': 'user',
      'content': [
        {
          'type': 'image_url',
          'image_url': {'url': image},
        },
      ],
    });
  });

  test('prompt isolate JSON round-trip preserves every attachment', () {
    const original = PromptMessage(
      role: 'user',
      content: 'Describe',
      sourceMessageId: 'm1',
      imagePaths: [image, second],
    );

    final restored = PromptMessage.fromJson(original.toJson());

    expect(restored.imagePaths, [image, second]);
    expect(restored.sourceMessageId, 'm1');
    expect(restored.toApiMap(), original.toApiMap());
  });

  test('prompt isolate JSON still reads a pre-multi-attach payload', () {
    final restored = PromptMessage.fromJson(const {
      'role': 'user',
      'content': 'Describe',
      'imagePath': image,
    });

    expect(restored.imagePaths, [image]);
  });

  test('prompt regex reconstruction preserves the attachments', () {
    const original = PromptMessage(
      role: 'user',
      content: 'Describe',
      isHistory: true,
      imagePaths: [image, second],
    );

    final result = applyPromptRegexes(
      messages: const [original],
      char: const Character(id: 'c1', name: 'Character'),
      sessionVars: const {},
      globalVars: const {},
      regexScripts: const [
        PresetRegex(
          id: 'r1',
          name: 'replace',
          regex: 'Describe',
          replacement: 'Inspect',
          promptOnly: true,
        ),
      ],
    );

    expect(result.single.imagePaths, [image, second]);
    expect(result.single.content, 'Inspect');
  });

  test('append-to-last reconstruction preserves the attachments', () {
    final history = <PromptMessage>[
      const PromptMessage(
        role: 'user',
        content: 'Describe',
        isHistory: true,
        sourceMessageId: 'm1',
        imagePaths: [image, second],
      ),
    ];

    applyAppendToLastMessage(history, const [
      (name: 'Instruction', content: 'Be concise'),
    ]);

    expect(history.single.imagePaths, [image, second]);
    expect(history.single.sourceMessageId, 'm1');
    expect(history.single.content, 'Describe\n\nBe concise');
  });

  test('Studio history limiting preserves the attachments', () {
    const original = PromptMessage(
      role: 'user',
      content: 'Describe',
      imagePaths: [image, second],
    );

    final finalHistory = StudioHistoryLimiter.limitFinalHistory(const [
      original,
    ], const StudioPreset(id: 's1'));
    final trackerHistory = StudioHistoryLimiter.limitTrackerHistory(const [
      original,
    ], 10);

    expect(finalHistory.single.imagePaths, [image, second]);
    expect(trackerHistory.single.imagePaths, [image, second]);
  });

  group('ChatMessage attachments', () {
    test('reads a legacy single-image message', () {
      const message = ChatMessage(
        id: 'm1',
        role: 'user',
        content: '',
        imagePath: image,
      );

      expect(message.attachments, [image]);
      expect(message.hasAttachments, isTrue);
    });

    test('a message with no image has none', () {
      const message = ChatMessage(id: 'm1', role: 'user', content: 'hi');

      expect(message.attachments, isEmpty);
      expect(message.hasAttachments, isFalse);
    });

    test('splitAttachments stores the first apart from the rest', () {
      final split = splitAttachments(const [image, second, third]);

      expect(split.imagePath, image);
      expect(split.extraImagePaths, [second, third]);
    });

    test('splitAttachments drops empties and answers null for nothing', () {
      expect(splitAttachments(const []).imagePath, isNull);
      expect(splitAttachments(const ['', '']).extraImagePaths, isEmpty);
      expect(splitAttachments(const ['', image]).imagePath, image);
    });
  });
}
