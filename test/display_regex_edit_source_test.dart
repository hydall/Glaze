import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/regex_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';

/// A display-only card renderer, the shape that broke: it consumes the very
/// marker it renders, so persisting its output leaves nothing to match on the
/// next pass.
const _cardRegex = PresetRegex(
  id: 'trk',
  name: 'Tracker',
  regex: r'/\{\s*TRK\s*\|\s*([^|}]*?)\s*\}/gi',
  replacement: '<div class="tk">\$1</div>',
  markdownOnly: true,
  runOnEdit: true,
);

void main() {
  const ctx = ChatMessageMapperContext(isGenerating: false);

  ChatMessage makeMsg(String content) =>
      ChatMessage(id: 'm1', role: 'assistant', content: content);

  group('ChatMessageMapper sourceText', () {
    test('carries the stored text when a display regex rewrites it', () {
      final map = ChatMessageMapper.toMap(
        makeMsg('Она вошла.\n\n{TRK | Дача}'),
        ctx,
        displayRegexes: const [_cardRegex],
      );

      expect(map['text'], 'Она вошла.\n\n<div class="tk">Дача</div>');
      expect(map['sourceText'], 'Она вошла.\n\n{TRK | Дача}');
    });

    test('omitted when the rendering equals the stored text', () {
      final map = ChatMessageMapper.toMap(
        makeMsg('Просто текст.'),
        ctx,
        displayRegexes: const [_cardRegex],
      );

      expect(map['text'], 'Просто текст.');
      expect(map.containsKey('sourceText'), isFalse);
    });

    test('omitted when no display regexes are configured', () {
      final map = ChatMessageMapper.toMap(makeMsg('{TRK | Дача}'), ctx);

      expect(map['text'], '{TRK | Дача}');
      expect(map.containsKey('sourceText'), isFalse);
    });
  });

  group('run-on-edit pass', () {
    // Mirrors ChatMessageOpsController._applyRunOnEditRegexes, which persists
    // its result and therefore runs with isMarkdown: false.
    test('markdownOnly script never rewrites stored text', () {
      final out = applyRegexes(
        '{TRK | Дача}',
        2,
        1,
        const [_cardRegex],
        const RegexApplyContext(),
        isMarkdown: false,
      );

      expect(out, '{TRK | Дача}');
    });

    test('a plain runOnEdit script still rewrites stored text', () {
      const plain = PresetRegex(
        id: 'plain',
        name: 'Plain',
        regex: '/foo/g',
        replacement: 'bar',
        runOnEdit: true,
      );

      final out = applyRegexes(
        'foo',
        2,
        1,
        const [plain],
        const RegexApplyContext(),
        isMarkdown: false,
      );

      expect(out, 'bar');
    });
  });
}
