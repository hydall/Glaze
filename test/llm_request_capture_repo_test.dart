import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';

LlmRequestCaptureEvent _event({
  required int sequence,
  String? sessionId = 'session',
  String stage = 'studio.final',
  String content = 'hello',
}) => LlmRequestCapture.build(
  ChatTransportRequest(
    endpoint: 'https://example.test',
    apiKey: 'secret',
    model: 'model',
    messages: [
      {'role': 'user', 'content': content},
    ],
    maxTokens: 20,
    temperature: 0.2,
    topP: 1,
    captureContext: LlmCaptureContext(
      stage: stage,
      sessionId: sessionId,
      logicalCallId: 'call-$sequence',
      attempt: sequence,
    ),
  ),
);

void main() {
  late AppDatabase db;
  late LlmRequestCaptureRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LlmRequestCaptureRepo(db);
  });

  tearDown(() async {
    await repo.close();
    await db.close();
  });

  test('persists sanitized event JSON and filters by stage', () async {
    await repo.record(_event(sequence: 1));
    await repo.record(_event(sequence: 2, stage: 'studio.controller'));

    final all = await repo.newestForSession('session');
    final finals = await repo.newestForSession(
      'session',
      stage: 'studio.final',
    );

    expect(all, hasLength(2));
    expect(finals.single.stage, 'studio.final');
    expect(jsonDecode(finals.single.eventJson), isA<Map<String, dynamic>>());
    expect(finals.single.eventJson, isNot(contains('secret')));
  });

  test('retains only the newest rows per session', () async {
    for (var i = 0; i <= LlmRequestCaptureRepo.maxRowsPerSession; i++) {
      await repo.record(_event(sequence: i));
    }

    final rows = await repo.newestForSession('session', limit: 100);
    expect(rows, hasLength(LlmRequestCaptureRepo.maxRowsPerSession));
    expect(rows.map((row) => row.attempt), isNot(contains(0)));
  });

  test('retains a separate bounded bucket without session context', () async {
    for (var i = 0; i <= LlmRequestCaptureRepo.maxRowsWithoutSession; i++) {
      await repo.record(_event(sequence: i, sessionId: null));
    }

    final rows = await repo.newestWithoutSession(limit: 200);
    expect(rows, hasLength(LlmRequestCaptureRepo.maxRowsWithoutSession));
  });

  test('oversized event is replaced with a valid summary', () async {
    final request = ChatTransportRequest(
      endpoint: 'https://example.test',
      apiKey: 'secret',
      model: 'model',
      messages: [
        for (var i = 0; i < 7; i++)
          {'role': 'user', 'content': '${'x' * 180000}$i'},
      ],
      maxTokens: 20,
      temperature: 0.2,
      topP: 1,
      captureContext: const LlmCaptureContext(
        stage: 'studio.final',
        sessionId: 'session',
      ),
    );
    await repo.record(LlmRequestCapture.build(request));

    final row = (await repo.newestForSession('session')).single;
    final stored = jsonDecode(row.eventJson) as Map<String, dynamic>;
    expect(row.truncated, isTrue);
    expect(stored['storageTruncated'], isTrue);
    expect(stored['sha256'], isA<String>());
  });

  test('deleteBySessionId leaves other sessions intact', () async {
    await repo.record(_event(sequence: 1));
    await repo.record(_event(sequence: 2, sessionId: 'other'));

    await repo.deleteBySessionId('session');

    expect(await repo.newestForSession('session'), isEmpty);
    expect(await repo.newestForSession('other'), hasLength(1));
  });
}
