import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/transport/call_attempt_outcome.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/features/chat/services/prompt_capture_view_service.dart';

/// The Prompt Inspector joins a captured request to what came back by
/// `callId + attempt`. The main request — the one that writes the reply —
/// carried neither, so `LlmRequestCaptureRepo._recordCallEvent` dropped its
/// outcome (it returns early when the callId is null) and the Response tab
/// could only ever say "nothing captured" for the one request a reader most
/// wants to read.
///
/// These tests hold both halves of that key in place from the two sides that
/// have to agree: the context the request is sent with, and the view that
/// matches the stored rows back up.
void main() {
  /// The capture row as `LlmRequestCaptureRepo` writes it from a context.
  LlmRequestCaptureRow rowFrom(LlmCaptureContext context, {String body = '{}'}) =>
      LlmRequestCaptureRow(
        id: 1,
        sequence: 1,
        createdAtMs: 0,
        sessionId: context.sessionId,
        stage: context.stage,
        messageId: context.messageId,
        pipelineRunId: context.pipelineRunId,
        callId: context.callId,
        attempt: context.attempt,
        truncated: false,
        eventJson: body,
      );

  /// The call-event row as the repo writes it from a transport event. Returns
  /// null for the contexts the repo refuses to store, which is the whole point.
  LlmCallEventRow? eventFrom(LlmCallEvent event) {
    final context = event.context;
    final pipelineRunId = context.pipelineRunId;
    final callId = context.callId;
    if (pipelineRunId == null || callId == null) return null;
    return LlmCallEventRow(
      id: event.id,
      createdAtMs: 0,
      sessionId: context.sessionId,
      pipelineRunId: pipelineRunId,
      callId: callId,
      stage: context.stage,
      attempt: context.attempt,
      kind: event.kind,
      status: event.status,
      statusCode: event.statusCode,
      responseText: event.responseText,
      error: event.error,
      payloadJson: jsonEncode(event.payload),
      truncated: event.truncated,
    );
  }

  LlmCallEvent succeeded(LlmCaptureContext context, String body) =>
      LlmCallEvent.transport(
        context: context,
        attempt: describeCallAttempt(attempt: 1, startedAtMs: 0, elapsedMs: 5),
        responseText: body,
      );

  const rawBody =
      '{"choices":[{"message":{"role":"assistant","content":"hello"}}]}';

  test('the main context carries every field the join needs', () {
    final context = mainCaptureContext(sessionId: 'sess', genId: 7);
    expect(context.stage, 'main');
    expect(context.sessionId, 'sess');
    expect(context.pipelineRunId, turnRunId('sess', 7));
    // The two that were missing, and the reason the tab was empty.
    expect(context.callId, isNotNull);
    expect(context.attempt, isNotNull);
  });

  test('the call id is derived, so both sides of the join compute it alike', () {
    expect(mainCallId('sess', 7), mainCallId('sess', 7));
    expect(mainCallId('sess', 7), isNot(mainCallId('sess', 8)));
    expect(mainCallId('other', 7), isNot(mainCallId('sess', 7)));
  });

  test('an ordinary turn carries no message id; a regenerate carries its target', () {
    expect(mainCaptureContext(sessionId: 's', genId: 1).messageId, isNull);
    expect(
      mainCaptureContext(sessionId: 's', genId: 1, messageId: 'msg-3').messageId,
      'msg-3',
    );
  });

  test('a main request now finds what came back', () {
    final context = mainCaptureContext(sessionId: 'sess', genId: 1);
    final event = eventFrom(succeeded(context, rawBody));
    expect(event, isNotNull, reason: 'the repo must be willing to store it');

    final view = PromptCaptureView.tryParse(
      rowFrom(context),
      callEvents: [event!],
    )!;
    expect(view.transportOutcome, isNotNull);
    expect(view.responseText, rawBody);
    expect(view.responseError, isNull);
  });

  test('a failed main request surfaces the error, not silence', () {
    final context = mainCaptureContext(sessionId: 'sess', genId: 1);
    final event = eventFrom(
      LlmCallEvent.transport(
        context: context,
        attempt: describeCallAttempt(
          attempt: 1,
          startedAtMs: 0,
          elapsedMs: 5,
          error: Exception('provider said no'),
        ),
      ),
    )!;
    final view = PromptCaptureView.tryParse(
      rowFrom(context),
      callEvents: [event],
    )!;
    expect(view.responseError, contains('provider said no'));
    expect(view.responseText, isNull);
  });

  test('negative control: with no call id the outcome is never stored', () {
    // The context the main request used to be sent with.
    const context = LlmCaptureContext(
      stage: 'main',
      sessionId: 'sess',
      pipelineRunId: 'turn:sess:1',
    );
    expect(
      eventFrom(succeeded(context, rawBody)),
      isNull,
      reason: 'the repo drops an event whose callId is null',
    );

    // And so the view has nothing to show — the reported symptom exactly.
    final view = PromptCaptureView.tryParse(rowFrom(context))!;
    expect(view.transportOutcome, isNull);
    expect(view.responseText, isNull);
  });

  test('negative control: an outcome whose attempt disagrees is not this one', () {
    final context = mainCaptureContext(sessionId: 'sess', genId: 1);
    final event = eventFrom(
      LlmCallEvent.transport(
        context: context,
        attempt: describeCallAttempt(
          attempt: 2,
          startedAtMs: 0,
          elapsedMs: 5,
          error: Exception('a later retry'),
        ),
      ),
    )!;
    final view = PromptCaptureView.tryParse(
      rowFrom(context),
      callEvents: [event],
    )!;
    // transportOutcome is attempt-exact, which is why the row has to carry one.
    expect(view.transportOutcome, isNull);
    expect(view.responseError, isNull);
  });
}
