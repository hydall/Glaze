import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/gemini_messages.dart';

void main() {
  group('convertGoogleMessages', () {
    test('leading system run becomes systemInstruction.parts', () {
      final r = convertGoogleMessages([
        {'role': 'system', 'content': 'rules A'},
        {'role': 'system', 'content': 'rules B'},
        {'role': 'user', 'content': 'hi'},
      ]);
      final sysParts = r.systemInstruction['parts'] as List;
      expect(sysParts, hasLength(2));
      expect(sysParts[0], {'text': 'rules A'});
      expect(sysParts[1], {'text': 'rules B'});
      expect(r.contents, hasLength(1));
      expect(r.contents[0]['role'], 'user');
    });

    test('assistant role becomes model', () {
      final r = convertGoogleMessages([
        {'role': 'user', 'content': 'q'},
        {'role': 'assistant', 'content': 'a'},
      ]);
      expect(r.contents[0]['role'], 'user');
      expect(r.contents[1]['role'], 'model');
    });

    test('squashes consecutive same-role contents', () {
      final r = convertGoogleMessages([
        {'role': 'user', 'content': 'one'},
        {'role': 'user', 'content': 'two'},
      ]);
      expect(r.contents, hasLength(1));
      final parts = r.contents[0]['parts'] as List;
      expect(parts, hasLength(1));
      expect(parts[0]['text'], 'one\n\ntwo');
    });

    test('image_url with data URL becomes inlineData', () {
      final dataUrl = 'data:image/png;base64,QUJDREVG';
      final r = convertGoogleMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ],
        },
      ]);
      final parts = r.contents[0]['parts'] as List;
      expect(parts, hasLength(2));
      expect(parts[0]['text'], 'look');
      expect(parts[1]['inlineData']['mimeType'], 'image/png');
      expect(parts[1]['inlineData']['data'], 'QUJDREVG');
    });

    test('preserves only the leading system run; mid-system becomes user', () {
      final r = convertGoogleMessages([
        {'role': 'system', 'content': 'leader'},
        {'role': 'user', 'content': 'q'},
        {'role': 'system', 'content': 'mid'},
        {'role': 'assistant', 'content': 'a'},
      ]);
      expect((r.systemInstruction['parts'] as List), hasLength(1));
      expect(r.contents, hasLength(2));
      // user "q" + system→user "mid" got squashed.
      final firstParts = r.contents[0]['parts'] as List;
      expect(firstParts[0]['text'], 'q\n\nmid');
      expect(r.contents[1]['role'], 'model');
    });

    test('useSystemInstruction=false keeps system in contents', () {
      final r = convertGoogleMessages(
        [
          {'role': 'system', 'content': 'sys'},
          {'role': 'user', 'content': 'u'},
        ],
        useSystemInstruction: false,
      );
      expect((r.systemInstruction['parts'] as List), isEmpty);
      // system → user, then merged with user.
      expect(r.contents, hasLength(1));
      expect(r.contents[0]['role'], 'user');
    });
  });

  group('convertGoogleMessagesMerged', () {
    test('collapses fragmented non-assistant chrome then converts', () {
      final r = convertGoogleMessagesMerged([
        {'role': 'system', 'content': 'sysA'},
        {'role': 'user', 'content': 'block1'},
        {'role': 'system', 'content': 'sysB'},
        {'role': 'user', 'content': 'block2'},
        {'role': 'assistant', 'content': 'ack'},
        {'role': 'user', 'content': 'follow'},
      ]);
      // After merge: one giant system + assistant + one giant system.
      // First system run lands in systemInstruction; trailing non-assistant
      // chrome stays in contents as merged-role messages.
      expect((r.systemInstruction['parts'] as List).isNotEmpty, isTrue);
      // contents must alternate model/user (and start with neither system).
      for (final c in r.contents) {
        expect(['user', 'model'], contains(c['role']));
      }
    });
  });
}
