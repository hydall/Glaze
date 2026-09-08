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
  );
}

void main() {
  group('buildGenerateUrl', () {
    test('streaming URL has streamGenerateContent + alt=sse', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint: 'https://generativelanguage.googleapis.com',
        model: 'gemini-2.5-flash',
        apiKey: 'k',
        stream: true,
      );
      expect(
        url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-flash:streamGenerateContent?key=k&alt=sse',
      );
    });

    test('non-stream URL uses generateContent', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint: 'https://generativelanguage.googleapis.com',
        model: 'gemini-2.5-pro',
        apiKey: 'k',
        stream: false,
      );
      expect(
        url,
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.5-pro:generateContent?key=k',
      );
    });

    test('api key with special chars is URL-encoded', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint: 'https://generativelanguage.googleapis.com',
        model: 'gemini-2.5-flash',
        apiKey: 'k/with+chars',
        stream: false,
      );
      expect(url, contains('key=k%2Fwith%2Bchars'));
    });

    test('schemeless endpoint gets https prefix', () {
      final url = GeminiChatTransport.buildGenerateUrl(
        endpoint: 'example.com',
        model: 'gemini-2.5-flash',
        apiKey: 'k',
        stream: false,
      );
      expect(url.startsWith('https://example.com/'), isTrue);
    });
  });

  group('buildRequest — body shape', () {
    test('emits contents + safetySettings + generationConfig', () {
      // With a [system, user] input, mergeNonAssistant collapses both into
      // one block; convertGoogleMessages bypasses systemInstruction (needs
      // > 1 message remaining), so the merged chrome becomes a user-role
      // content. The body still has safetySettings + generationConfig.
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
      'multi-turn chat: leading merged system survives as systemInstruction',
      () {
        // With a real chat (system + first user + first assistant + new user),
        // the merge collapses only the leading non-assistant block, and the
        // converter extracts that block into systemInstruction because
        // messages remain after pop.
        final built = GeminiChatTransport.buildRequest(
          _req(
            messages: [
              {'role': 'system', 'content': 'sysA'},
              {'role': 'user', 'content': 'q1'},
              {'role': 'assistant', 'content': 'a1'},
              {'role': 'user', 'content': 'q2'},
            ],
          ),
        );
        final sys = built.body['systemInstruction'] as Map;
        expect((sys['parts'] as List).first['text'], 'sysA\n\nq1');
        final contents = built.body['contents'] as List;
        expect(contents.first['role'], 'model');
      },
    );

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
      // After mergeNonAssistant collapses [system, user] → one block, the
      // converter extracts it as systemInstruction (length > 1 remaining),
      // leaving only the assistant turn → contents[0] is role=model.
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
      expect(contents, hasLength(1));
      expect(contents[0]['role'], 'model');
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
