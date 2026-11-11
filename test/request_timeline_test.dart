import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/features/chat/services/prompt_capture_view_service.dart';
import 'package:glaze_flutter/features/chat/state/request_timeline.dart';
import 'package:glaze_flutter/features/chat/widgets/requests/request_stage_label.dart';

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
  test('every stage of a turn is its own row, newest first', () {
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

    expect(groups, hasLength(4));
    expect(groups.every((g) => g.entries.length == 1), isTrue);
    expect(groups.map((g) => g.entries.single.stage), [
      'ledger.turn',
      'cleaner.rewrite',
      'main',
      'studio.controller',
    ]);
    // Each row still knows its turn.
    expect(groups.every((g) => g.kind == RequestGroupKind.turn), isTrue);
    expect(groups.every((g) => g.messageId == 'm1'), isTrue);
  });

  test('a step re-run later sits at its own time, not under the old turn', () {
    final groups = buildRequestTimeline([
      _capture(id: 1, createdAtMs: 100, stage: 'main', messageId: 'm1'),
      _capture(id: 2, createdAtMs: 200, stage: 'main', messageId: 'm2'),
      _capture(
        id: 3,
        createdAtMs: 900,
        stage: 'extblock.status',
        messageId: 'm1',
        callId: 'extblock:status:m1#0',
      ),
    ]);

    expect(groups.map((g) => g.startedAtMs), [900, 200, 100]);
    expect(groups.first.messageId, 'm1');
  });

  test('retries of one call collapse into a single row', () {
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
    expect(groups.single.hasRetry, isTrue);
  });

  test('a call id reused by a later run is not taken for a retry', () {
    // The main request's id came from a counter that started over with every
    // app run, so two unrelated turns could carry the same one.
    final groups = buildRequestTimeline([
      _capture(
        id: 1,
        createdAtMs: 100,
        stage: 'main',
        pipelineRunId: 'turn:session:1',
        callId: 'call:main:session:1',
      ),
      _capture(
        id: 2,
        createdAtMs: 900,
        stage: 'main',
        pipelineRunId: 'turn:session:1',
        callId: 'call:main:session:1',
      ),
    ]);

    expect(groups, hasLength(2));
    expect(groups.every((g) => g.entries.single.attempts == 1), isTrue);
  });

  test('a background job is a row of its own, in its place in time', () {
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

  test('the app restart separator sits above the first earlier request', () {
    final groups = buildRequestTimeline([
      _capture(id: 1, createdAtMs: 100, stage: 'main', messageId: 'm1'),
      _capture(id: 2, createdAtMs: 200, stage: 'main', messageId: 'm2'),
      _capture(id: 3, createdAtMs: 900, stage: 'main', messageId: 'm3'),
    ]);

    // Started at 500: one request of this run above, two earlier below.
    expect(restartSeparatorIndex(groups, 500), 1);
    // Nothing from this run yet: the separator heads the list.
    expect(restartSeparatorIndex(groups, 1000), 0);
    // Nothing from before the restart: no separator.
    expect(restartSeparatorIndex(groups, 50), isNull);
  });

  test('a request from another day shows its date', () {
    final now = DateTime(2026, 11, 11, 15);
    expect(
      formatRequestTime(DateTime(2026, 11, 11, 9, 5, 7), now: now),
      '09:05:07',
    );
    expect(
      formatRequestTime(DateTime(2026, 11, 10, 9, 5, 7), now: now),
      '10.11 09:05:07',
    );
    expect(
      formatRequestTime(DateTime(2025, 1, 2, 3, 4, 5), now: now),
      '02.01.2025 03:04:05',
    );
  });

  test('stage families cover every producer in the app', () {
    expect(requestStageFamily('main'), RequestStageFamily.main);
    expect(
      requestStageFamily('studio.post_processing'),
      RequestStageFamily.agent,
    );
    expect(requestStageFamily('cleaner.audit'), RequestStageFamily.cleaner);
    expect(requestStageFamily('ledger.turn_repair'), RequestStageFamily.ledger);
    expect(requestStageFamily('extblock.status'), RequestStageFamily.extBlock);
    expect(requestStageFamily('card.collector'), RequestStageFamily.card);
    expect(requestStageFamily('lorebook_writer'), RequestStageFamily.card);
    expect(requestStageFamily('summary'), RequestStageFamily.summary);
    expect(requestStageFamily('memory.draft'), RequestStageFamily.memory);
    expect(
      requestStageFamily('embedding.lorebook'),
      RequestStageFamily.embedding,
    );
    expect(requestStageFamily('image.generate'), RequestStageFamily.image);
    expect(requestStageFamily('image.plugin'), RequestStageFamily.image);
    expect(requestStageFamily('plugin.generate'), RequestStageFamily.plugin);
    expect(requestStageFamily(null), RequestStageFamily.other);
  });
}
