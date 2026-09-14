import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../models/agent_operation_record.dart';

/// Describes a finished LLM call attempt for the diagnostics tables.
///
/// The status labels are the vocabulary `AgentOperationAttempt.status`
/// already carries — `ok`, `timeout`, `cancelled`, `http_4xx`, `http_5xx`,
/// `connection_closed`, `socket_error`, `error`. Extracted from
/// `AuxRetryRunner`, which is where they were first written and where they
/// were private: the main chat stream has no retry runner of its own, so it
/// had no way to classify its own outcome the same way and its call events
/// would otherwise have read differently from every other call in the app.
AgentOperationAttempt describeCallAttempt({
  required int attempt,
  required int startedAtMs,
  required int elapsedMs,
  Object? error,
}) {
  if (error == null) {
    return AgentOperationAttempt(
      attempt: attempt,
      statusCode: 200,
      status: 'ok',
      startedAtMs: startedAtMs,
      elapsedMs: elapsedMs,
    );
  }
  return AgentOperationAttempt(
    attempt: attempt,
    statusCode: callAttemptStatusCode(error),
    status: callAttemptStatus(error),
    error: boundedAttemptError(error),
    startedAtMs: startedAtMs,
    elapsedMs: elapsedMs,
  );
}

/// The provider's status code when the failure carries one, 0 otherwise — a
/// timeout or a dropped socket never had a response to read it from.
int callAttemptStatusCode(Object error) =>
    error is DioException ? (error.response?.statusCode ?? 0) : 0;

String callAttemptStatus(Object error) {
  if (error is TimeoutException) return 'timeout';
  if (error is HttpException) return 'connection_closed';
  if (error is SocketException) return 'socket_error';
  if (error is DioException) {
    // A cancel is not a failure of the provider's, and it is checked before
    // the status code because a cancelled request has no response at all.
    if (CancelToken.isCancel(error)) return 'cancelled';
    final code = error.response?.statusCode ?? 0;
    if (code >= 500 && code < 600) return 'http_5xx';
    if (code >= 400 && code < 500) return 'http_4xx';
  }
  return 'error';
}

/// `AgentOperationAttempt.error` is documented as truncated to 500 chars, and
/// a provider that answers with a page of HTML would otherwise put all of it
/// in every attempt row.
String boundedAttemptError(Object error) {
  final text = error.toString();
  return text.length > 500 ? '${text.substring(0, 500)}…' : text;
}
