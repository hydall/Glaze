import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/summary_repo.dart';
import 'package:glaze_flutter/core/llm/summary_service.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromBytes(
      utf8.encode(
        '{"choices":[{"message":{"content":"  generated summary  "}}]}',
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late SummaryRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SummaryRepo(db);
  });

  tearDown(() => db.close());

  test('reads defaults and persists trimmed manual summary state', () async {
    final service = SummaryService(repo);

    expect(await service.getSummary('session'), isNull);
    expect(await service.getSummaryContent('session'), isNull);
    expect(await service.isSummaryEnabled('session'), isTrue);
    expect(await service.getSummaryMessageCount('session'), 0);

    await service.setSummary(
      sessionId: 'session',
      content: '  manual summary  ',
      messageCount: 7,
    );
    expect(await service.getSummary('session'), 'manual summary');
    expect(await service.getSummaryMessageCount('session'), 7);

    await service.setSummaryEnabled(sessionId: 'session', enabled: false);
    expect(await service.getSummary('session'), isNull);
    expect(await service.getSummaryContent('session'), 'manual summary');
    expect(await service.isSummaryEnabled('session'), isFalse);

    await service.deleteSummary('session');
    expect(await service.getSummaryContent('session'), isNull);
  });

  test(
    'generates with filtered history and persists the trimmed response',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final service = SummaryService(repo, dio);
      const history = [
        ChatMessage(id: '1', role: 'user', content: 'Hello'),
        ChatMessage(id: '2', role: 'system', content: 'Ignored'),
        ChatMessage(id: '3', role: 'assistant', content: 'Hi there'),
      ];

      final result = await service.generateSummary(
        sessionId: 'session',
        history: history,
        apiConfig: const ApiConfig(
          id: 'api',
          endpoint: 'https://example.com/v1',
          apiKey: 'secret',
          model: 'model',
        ),
        customPrompt: 'Context:\n{{history}}',
      );

      expect(result, 'generated summary');
      expect(
        adapter.request?.uri.toString(),
        'https://example.com/v1/chat/completions',
      );
      expect(adapter.request?.headers['Authorization'], 'Bearer secret');
      final data = adapter.request?.data as Map<String, dynamic>;
      final messages = data['messages'] as List<dynamic>;
      final prompt = (messages.single as Map<String, dynamic>)['content'];
      expect(prompt, contains('User: Hello'));
      expect(prompt, contains('Character: Hi there'));
      expect(prompt, isNot(contains('Ignored')));
      expect(await service.getSummaryContent('session'), 'generated summary');
      expect(await service.getSummaryMessageCount('session'), history.length);
      expect((await repo.get('session'))?.prompt, 'Context:\n{{history}}');
    },
  );

  test(
    'rejects incomplete API configuration before making a request',
    () async {
      final service = SummaryService(repo);

      await expectLater(
        service.generateSummary(
          sessionId: 'session',
          history: const [],
          apiConfig: const ApiConfig(id: 'api', model: 'model'),
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        service.generateSummary(
          sessionId: 'session',
          history: const [],
          apiConfig: const ApiConfig(
            id: 'api',
            endpoint: 'https://example.com',
          ),
        ),
        throwsA(isA<Exception>()),
      );
    },
  );

  test('regeneration threshold behavior is unchanged', () {
    final service = SummaryService(repo);

    expect(service.needsRegeneration(5, null), isTrue);
    expect(service.needsRegeneration(10, 8), isFalse);
    expect(service.needsRegeneration(13, 10), isTrue);
  });
}
