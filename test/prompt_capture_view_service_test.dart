import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/features/chat/services/prompt_capture_view_service.dart';

LlmRequestCaptureEvent _event({
  required String stage,
  required String content,
  required DateTime createdAt,
}) {
  final captured = LlmRequestCapture.build(
    ChatTransportRequest(
      endpoint: 'https://example.test/v1/chat',
      apiKey: 'secret',
      model: 'test-model',
      messages: [
        {'role': 'user', 'content': content},
      ],
      maxTokens: 64,
      temperature: 0.2,
      topP: 1,
      captureContext: LlmCaptureContext(
        stage: stage,
        sessionId: 'session',
        attempt: 1,
      ),
    ),
    protocol: 'openai',
  );
  return LlmRequestCaptureEvent(
    sequence: captured.sequence,
    createdAt: createdAt,
    protocol: captured.protocol,
    context: captured.context,
    request: captured.request,
    truncated: captured.truncated,
  );
}

void main() {
  late AppDatabase db;
  late LlmRequestCaptureRepo repo;
  late PromptCaptureViewService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LlmRequestCaptureRepo(db);
    service = PromptCaptureViewService(repo);
  });

  tearDown(() async {
    await repo.close();
    await db.close();
  });

  test(
    'loads newest captures with stage labels and decoded messages',
    () async {
      await repo.record(
        _event(
          stage: 'ledger.reconciliation',
          content: 'older',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await repo.record(
        _event(
          stage: 'card.writer',
          content: 'newer',
          createdAt: DateTime.utc(2026, 1, 2),
        ),
      );

      final captures = await service.load('session');

      expect(captures.map((item) => item.label), [
        'Card writer',
        'Reconciliation',
      ]);
      expect(captures.first.messages.single, {
        'role': 'user',
        'content': 'newer',
      });
      expect(jsonDecode(captures.first.formattedJson)['model'], 'test-model');
    },
  );

  test('skips malformed diagnostic rows', () async {
    await db
        .into(db.llmRequestCaptureRows)
        .insert(
          LlmRequestCaptureRowsCompanion.insert(
            sequence: 1,
            createdAtMs: 1,
            sessionId: const Value('session'),
            truncated: false,
            eventJson: '{not json',
          ),
        );

    expect(await service.load('session'), isEmpty);
  });
}
