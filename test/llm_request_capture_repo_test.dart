import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';

LlmRequestCaptureEvent _event({
  required int sequence,
  String? sessionId = 'session',
  String stage = 'studio.final',
  String content = 'hello',
  String? pipelineRunId,
  String? callId,
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
      pipelineRunId: pipelineRunId ?? 'pipeline-$sequence',
      callId: callId ?? 'call-$sequence',
      attempt: sequence,
    ),
  ),
);

LlmRequestCaptureEvent _fatEvent({
  required int sequence,
  required List<Map<String, dynamic>> messages,
}) => LlmRequestCapture.build(
  ChatTransportRequest(
    endpoint: 'https://example.test',
    apiKey: 'secret',
    model: 'model',
    messages: messages,
    maxTokens: 20,
    temperature: 0.2,
    topP: 1,
    captureContext: LlmCaptureContext(
      stage: 'studio.final',
      sessionId: 'session',
      pipelineRunId: 'pipeline-$sequence',
      callId: 'call-$sequence',
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

    final rows = await repo.newestForSession(
      'session',
      limit: LlmRequestCaptureRepo.maxRowsPerSession + 10,
    );
    expect(rows, hasLength(LlmRequestCaptureRepo.maxRowsPerSession));
    expect(rows.map((row) => row.attempt), isNot(contains(0)));
  });

  test('byte budget evicts before the row ceiling is reached', () async {
    // Four 190k-char messages per request — just under the per-string
    // sanitizer cap, so each row lands at roughly 0.77 MB. Twelve of them is
    // ~9 MB against a 6 MB session budget, and the 200-row ceiling is never
    // approached: the bytes are what evict.
    final fat = [
      for (var i = 0; i < 4; i++) {'role': 'user', 'content': 'x' * 190000},
    ];
    for (var i = 0; i < 12; i++) {
      await repo.record(_fatEvent(sequence: i, messages: fat));
    }

    final rows = await repo.newestForSession(
      'session',
      limit: LlmRequestCaptureRepo.maxRowsPerSession,
    );

    expect(rows.length, lessThan(12), reason: 'the byte budget bit');
    expect(
      rows.length,
      greaterThanOrEqualTo(LlmRequestCaptureRepo.minRowsPerSession),
      reason: 'the floor keeps the newest rows whatever their size',
    );
    expect(rows.first.attempt, 11, reason: 'newest survive, oldest go');
  });

  test('a single oversized capture never empties the list', () async {
    for (var i = 0; i < 5; i++) {
      await repo.record(_event(sequence: i, content: 'small'));
    }
    await repo.record(
      _fatEvent(
        sequence: 99,
        messages: [
          for (var i = 0; i < 7; i++)
            {'role': 'user', 'content': '${'y' * 180000}$i'},
        ],
      ),
    );

    final rows = await repo.newestForSession('session');
    expect(rows, hasLength(6));
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

  test('links immutable transport and parser events by call id', () async {
    const context = LlmCaptureContext(
      stage: 'ledger.reconciliation',
      sessionId: 'session',
      pipelineRunId: 'pipeline-1',
      callId: 'call-1',
      logicalCallId: 'range-1',
    );
    await repo.recordCallEvent(
      LlmCallEvent.transport(
        context: context,
        attempt: const AgentOperationAttempt(
          attempt: 1,
          statusCode: 200,
          status: 'ok',
          startedAtMs: 1,
          elapsedMs: 2,
        ),
        responseText: '{"export":[]}',
      ),
    );
    await repo.recordCallEvent(
      LlmCallEvent.parserVerdict(
        context: context.withAttempt(1),
        parserName: 'StudioLedgerExportParser',
        accepted: true,
        code: 'accepted',
      ),
    );

    final rows = await repo.callEvents('call-1');
    expect(rows.map((row) => row.kind), [
      'transport_succeeded',
      'parser_accepted',
    ]);
    expect(rows.first.responseHash, isNotEmpty);
    expect(rows.last.parserCode, 'accepted');

    expect(
      () => db
          .update(db.llmCallEventRows)
          .write(const LlmCallEventRowsCompanion(status: Value('changed'))),
      throwsA(anything),
    );
  });
}
