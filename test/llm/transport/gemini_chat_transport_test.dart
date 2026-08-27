import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/gemini_chat_transport.dart';

ChatTransportRequest _req({
  String model = 'gemini-2.5-flash',
  List<Map<String, dynamic>>? messages,
  int maxTokens = 4000,
  double temperature = 0.7,
  double topP = 0.9,
  int topK = 0,
  bool omitTopK = false,
  bool stream = true,
  bool requestReasoning = false,
  String? reasoningEffort,
  bool useSystemInstruction = true,
}) {
  return ChatTransportRequest(
    endpoint: 'https://generativelanguage.googleapis.com',
    apiKey: 'AIza-test',
    model: model,
    messages:
        messages ??
        [
          {'role': 'system', 'content': 'be helpful'},
          {'role': 'user', 'content': 'hi'},
        ],
    maxTokens: maxTokens,
    temperature: temperature,
    topP: topP,
    topK: topK,
    omitTopK: omitTopK,
    stream: stream,
    requestReasoning: requestReasoning,
    reasoningEffort: reasoningEffort,
    useSystemInstruction: useSystemInstruction,
  );
}

void main() {
  group('buildGenerateUrl', () {
    test('streaming URL has streamGenerateContent + alt=sse', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint:
            'https://generativelanguage.googleapis.com/v1beta/models/'
            'gemini-2.5-flash:streamGenerateContent',
        apiKey: 'k',
      );
      expect(
        url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-flash:streamGenerateContent?key=k&alt=sse',
      );
    });

    test('non-stream URL uses generateContent', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint:
            'https://generativelanguage.googleapis.com/v1beta/models/'
            'gemini-2.5-pro:generateContent',
        apiKey: 'k',
      );
      expect(
        url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-pro:generateContent?key=k',
      );
    });

    test('api key with special chars is URL-encoded', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint:
            'https://generativelanguage.googleapis.com/v1beta/models/'
            'gemini-2.5-flash:generateContent',
        apiKey: 'k/with+chars',
      );
      expect(url, contains('key=k%2Fwith%2Bchars'));
    });

    test('existing query parameters are preserved', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint:
            'https://example.com/v1beta/models/'
            'gemini-2.5-flash:generateContent?region=eu',
        apiKey: 'k',
      );
      expect(url, contains('region=eu'));
      expect(url, contains('key=k'));
    });
  });

  group('buildRequest — body shape', () {
    test('emits contents + safetySettings + generationConfig', () {
      final built = GeminiChatTransport.buildRequest(_req());
      expect(built.body['contents'], isA<List<dynamic>>());

      final safety = built.body['safetySettings'] as List;
      expect(safety, hasLength(5));
      expect(safety[0], {
        'category': 'HARM_CATEGORY_HARASSMENT',
        'threshold': 'OFF',
      });
    });

    test(
      'only the leading system run is hoisted — the first user turn stays',
      () {
        final built = GeminiChatTransport.buildRequest(
          _req(
            messages: [
              {'role': 'system', 'content': 'sysA'},
              {'role': 'system', 'content': 'sysB'},
              {'role': 'user', 'content': 'q1'},
              {'role': 'assistant', 'content': 'a1'},
              {'role': 'user', 'content': 'q2'},
            ],
          ),
        );
        // One part per system message, exactly like SillyTavern.
        expect((built.body['systemInstruction'] as Map)['parts'], [
          {'text': 'sysA'},
          {'text': 'sysB'},
        ]);
        final contents = built.body['contents'] as List;
        expect(contents.map((c) => c['role']), ['user', 'model', 'user']);
        expect((contents.first['parts'] as List).first, {'text': 'q1'});
      },
    );

    test('a leading user turn is never treated as system chrome', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          messages: [
            {'role': 'user', 'content': 'q1'},
            {'role': 'assistant', 'content': 'a1'},
            {'role': 'user', 'content': 'q2'},
          ],
        ),
      );
      expect(built.body.containsKey('systemInstruction'), isFalse);
      final contents = built.body['contents'] as List;
      expect(contents.map((c) => c['role']), ['user', 'model', 'user']);
    });

    test('omits systemInstruction when no leading system run', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
        ),
      );
      expect(built.body.containsKey('systemInstruction'), isFalse);
    });

    test('useSystemInstruction: false keeps the system block inline', () {
      const messages = [
        {'role': 'system', 'content': 'sysA'},
        {'role': 'user', 'content': 'q1'},
        {'role': 'assistant', 'content': 'a1'},
        {'role': 'user', 'content': 'q2'},
      ];

      final hoisted = GeminiChatTransport.buildRequest(
        _req(messages: messages),
      );
      expect((hoisted.body['systemInstruction'] as Map)['parts'], [
        {'text': 'sysA'},
      ]);

      final inline = GeminiChatTransport.buildRequest(
        _req(messages: messages, useSystemInstruction: false),
      );
      expect(inline.body.containsKey('systemInstruction'), isFalse);
      // The block is not dropped — it becomes the first user turn, squashed
      // with the user message that follows it.
      final contents = inline.body['contents'] as List;
      expect(contents.first['role'], 'user');
      expect((contents.first['parts'] as List).first, {'text': 'sysA\n\nq1'});
    });

    test('system turns after the opening block are always user turns', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          messages: [
            {'role': 'system', 'content': 'sysA'},
            {'role': 'user', 'content': 'q1'},
            {'role': 'assistant', 'content': 'a1'},
            {'role': 'system', 'content': 'mid-chat note'},
            {'role': 'user', 'content': 'q2'},
          ],
        ),
      );
      final contents = built.body['contents'] as List;
      // q1 stays a user turn; the mid-chat system note becomes a user turn and
      // is squashed with the user message that follows it.
      expect(contents.map((c) => c['role']), ['user', 'model', 'user']);
      expect((contents.last['parts'] as List).first, {
        'text': 'mid-chat note\n\nq2',
      });
    });

    test('temperature/topP in generationConfig', () {
      final built = GeminiChatTransport.buildRequest(_req());
      final cfg = built.body['generationConfig'] as Map;
      expect(cfg['temperature'], 0.7);
      expect(cfg['topP'], 0.9);
      expect(cfg['maxOutputTokens'], 4000);
      expect(cfg['candidateCount'], 1);
    });

    test('omitTopK removes topK', () {
      final included = GeminiChatTransport.buildRequest(_req(topK: 40));
      final omitted = GeminiChatTransport.buildRequest(
        _req(topK: 40, omitTopK: true),
      );

      expect((included.body['generationConfig'] as Map)['topK'], 40);
      expect(omitted.body['generationConfig'] as Map, isNot(contains('topK')));
    });

    test('assistant role mapped to model in contents', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          messages: [
            {'role': 'system', 'content': 's'},
            {'role': 'user', 'content': 'q'},
            {'role': 'assistant', 'content': 'a'},
          ],
        ),
      );
      final contents = built.body['contents'] as List;
      expect(contents, hasLength(2));
      expect(contents.map((c) => c['role']), ['user', 'model']);
    });
  });

  group('buildRequest — thinking', () {
    test('gemini-2.5-flash medium → integer budget in thinkingConfig', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          model: 'gemini-2.5-flash',
          requestReasoning: true,
          reasoningEffort: 'medium',
          maxTokens: 10000,
        ),
      );
      final cfg = built.body['generationConfig'] as Map;
      final tc = cfg['thinkingConfig'] as Map;
      expect(tc['includeThoughts'], true);
      expect(tc['thinkingBudget'], 2500); // 25% of 10000
    });

    test('gemini-3-pro medium → thinkingLevel symbolic', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          model: 'gemini-3-pro',
          requestReasoning: true,
          reasoningEffort: 'medium',
        ),
      );
      final cfg = built.body['generationConfig'] as Map;
      final tc = cfg['thinkingConfig'] as Map;
      // gemini-3-pro maps medium → 'low' (per port).
      expect(tc['thinkingLevel'], 'low');
      expect(tc.containsKey('thinkingBudget'), isFalse);
    });

    test('non-thinking model omits thinkingConfig', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          model: 'gemini-2.0-flash',
          requestReasoning: true,
          reasoningEffort: 'medium',
        ),
      );
      final cfg = built.body['generationConfig'] as Map;
      expect(cfg.containsKey('thinkingConfig'), isFalse);
    });

    test('requestReasoning=false omits thinkingConfig', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          model: 'gemini-2.5-pro',
          requestReasoning: false,
          reasoningEffort: 'high',
        ),
      );
      final cfg = built.body['generationConfig'] as Map;
      expect(cfg.containsKey('thinkingConfig'), isFalse);
    });
  });

  group('buildRequest — merge', () {
    test('non-assistant chrome merged before convert (alternating roles)', () {
      final built = GeminiChatTransport.buildRequest(
        _req(
          messages: [
            {'role': 'system', 'content': 'sysA'},
            {'role': 'user', 'content': 'first'},
            {'role': 'system', 'content': 'sysB'},
            {'role': 'user', 'content': 'second'},
            {'role': 'assistant', 'content': 'ack'},
            {'role': 'user', 'content': 'follow'},
          ],
        ),
      );
      final contents = built.body['contents'] as List;
      // Every role in contents must be user or model — no system in body.
      for (final c in contents) {
        expect(['user', 'model'], contains(c['role']));
      }
    });
  });
}
