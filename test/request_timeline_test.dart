import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/features/chat/services/prompt_capture_view_service.dart';
import 'package:glaze_flutter/features/chat/state/request_timeline.dart';

PromptCaptureView _capture({
  required int id,
  required int createdAtMs,
  String? stage,
  String? messageId,
  String? pipelineRunId,
  String? callId,
  String? agentId,
  int attempt = 1,
}) => PromptCaptureView.tryParse(
  LlmRequestCaptureRow(
    id: id,
    sequence: id,
    createdAtMs: createdAtMs,
    sessionId: 'session',
    stage: stage,
    messageId: messageId,
    pipelineRunId: pipelineRunId,
    callId: callId,
    agentId: agentId,
    attempt: attempt,
    truncated: false,
    eventJson: jsonEncode({
      'model': 'test-model',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
    }),
  ),
)!;

void main() {
  test('a turn folds every stage that shares its message id', () {
    final groups = buildRequestTimeline([
      _capture(
        id: 4,
        createdAtMs: 400,
        stage: 'ledger.turn',
        messageId: 'm1',
        callId: 'ledger-1',
      ),
      _capture(
        id: 3,
        createdAtMs: 300,
        stage: 'cleaner.rewrite',
        messageId: 'm1',
        callId: 'cleaner-1',
      ),
      _capture(id: 2, createdAtMs: 200, stage: 'main', messageId: 'm1'),
      _capture(
        id: 1,
        createdAtMs: 100,
        stage: 'studio.controller',
        messageId: 'm1',
        agentId: 'continuity',
      ),
    ]);

    expect(groups, hasLength(1));
    final turn = groups.single;
    expect(turn.kind, RequestGroupKind.turn);
    expect(turn.requestCount, 4);
    // Execution order, not the newest-first order the rows arrive in.
    expect(
      turn.entries.map((e) => e.stage),
      ['studio.controller', 'main', 'cleaner.rewrite', 'ledger.turn'],
    );
  });

  test('retries of one call collapse into a single step', () {
    final groups = buildRequestTimeline([
      _capture(
        id: 2,
        createdAtMs: 200,
        stage: 'ledger.turn',
        messageId: 'm1',
        callId: 'ledger-1',
        attempt: 2,
      ),
      _capture(
        id: 1,
        createdAtMs: 100,
        stage: 'ledger.turn',
        messageId: 'm1',
        callId: 'ledger-1',
        attempt: 1,
      ),
    ]);

    final entry = groups.single.entries.single;
    expect(entry.attempts, 2);
    expect(entry.capture.row.attempt, 2, reason: 'the last attempt is kept');
    expect(groups.single.requestCount, 2);
    expect(groups.single.hasRetry, isTrue);
  });

  test('a background job stays its own group, in its place in time', () {
    final groups = buildRequestTimeline([
      _capture(id: 3, createdAtMs: 300, stage: 'main', messageId: 'm2'),
      _capture(
        id: 2,
        createdAtMs: 200,
        stage: 'card_writer',
        pipelineRunId: 'job-7',
        callId: 'job-7-1',
      ),
      _capture(id: 1, createdAtMs: 100, stage: 'main', messageId: 'm1'),
    ]);

    expect(groups.map((g) => g.kind), [
      RequestGroupKind.turn,
      RequestGroupKind.task,
      RequestGroupKind.turn,
    ]);
    expect(groups[1].leadFamily, RequestStageFamily.card);
    expect(groups.map((g) => g.endedAtMs), [300, 200, 100]);
  });

  test('the turn is named by its generator, not by its last stage', () {
    final groups = buildRequestTimeline([
      _capture(
        id: 2,
        createdAtMs: 200,
        stage: 'cleaner.rewrite',
        messageId: 'm1',
        callId: 'c1',
      ),
      _capture(
        id: 1,
        createdAtMs: 100,
        stage: 'studio.final',
        messageId: 'm1',
        agentId: 'final',
      ),
    ]);

    expect(groups.single.leadFamily, RequestStageFamily.agent);
  });

  test('stage families cover every producer in the app', () {
    expect(requestStageFamily('main'), RequestStageFamily.main);
    expect(requestStageFamily('studio.post_processing'), RequestStageFamily.agent);
    expect(requestStageFamily('cleaner.audit'), RequestStageFamily.cleaner);
    expect(requestStageFamily('ledger.turn_repair'), RequestStageFamily.ledger);
    expect(requestStageFamily('extblock.status'), RequestStageFamily.extBlock);
    expect(requestStageFamily('card.collector'), RequestStageFamily.card);
    expect(requestStageFamily('lorebook_writer'), RequestStageFamily.card);
    expect(requestStageFamily('summary'), RequestStageFamily.summary);
    expect(requestStageFamily(null), RequestStageFamily.other);
  });
}
