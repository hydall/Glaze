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

  test('attachments are sent to the model unless the eye hides them', () {
    final visible = assembler.assemble([
      const ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'What is this?',
        imagePath: image,
      ),
    ]).single;
    final hidden = assembler.assemble([
      const ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'What is this?',
        imagePath: image,
        imageHidden: true,
      ),
    ]).single;

    expect(visible.hasImage, isTrue);
    expect(hidden.hasImage, isFalse);
    expect(hidden.toApiMap(), {'role': 'user', 'content': 'What is this?'});
  });

  test('image-only message remains a valid multimodal request', () {
    const prompt = PromptMessage(role: 'user', content: '', imagePath: image);

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

  test('prompt isolate JSON round-trip preserves the image', () {
    const original = PromptMessage(
      role: 'user',
      content: 'Describe',
      sourceMessageId: 'm1',
      imagePath: image,
    );

    final restored = PromptMessage.fromJson(original.toJson());

    expect(restored.imagePath, image);
    expect(restored.sourceMessageId, 'm1');
    expect(restored.toApiMap(), original.toApiMap());
  });

  test('prompt regex reconstruction preserves the image', () {
    const original = PromptMessage(
      role: 'user',
      content: 'Describe',
      isHistory: true,
      imagePath: image,
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

    expect(result.single.imagePath, image);
    expect(result.single.content, 'Inspect');
  });

  test('append-to-last reconstruction preserves the image', () {
    final history = <PromptMessage>[
      const PromptMessage(
        role: 'user',
        content: 'Describe',
        isHistory: true,
        sourceMessageId: 'm1',
        imagePath: image,
      ),
    ];

    applyAppendToLastMessage(history, const [
      (name: 'Instruction', content: 'Be concise'),
    ]);

    expect(history.single.imagePath, image);
    expect(history.single.sourceMessageId, 'm1');
    expect(history.single.content, 'Describe\n\nBe concise');
  });

  test('Studio history limiting preserves the image', () {
    const original = PromptMessage(
      role: 'user',
      content: 'Describe',
      imagePath: image,
    );

    final finalHistory = StudioHistoryLimiter.limitFinalHistory(const [
      original,
    ], const StudioConfig(sessionId: 's1'));
    final trackerHistory = StudioHistoryLimiter.limitTrackerHistory(const [
      original,
    ], 10);

    expect(finalHistory.single.imagePath, image);
    expect(trackerHistory.single.imagePath, image);
  });
}
