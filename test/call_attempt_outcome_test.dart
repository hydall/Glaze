import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/call_attempt_outcome.dart';

/// The status vocabulary the diagnostics tables carry. It used to live private
/// inside `AuxRetryRunner`, which is why the main chat stream — the one request
/// a reader most wants an outcome for — had no way to describe its own and
/// recorded nothing at all.
void main() {
  DioException dioWith(int? status) => DioException(
    requestOptions: RequestOptions(path: '/v1/chat/completions'),
    response: status == null
        ? null
        : Response<dynamic>(
            requestOptions: RequestOptions(path: '/v1/chat/completions'),
            statusCode: status,
          ),
  );

  test('a call that came back is ok, with no error text', () {
    final attempt = describeCallAttempt(
      attempt: 1,
      startedAtMs: 1000,
      elapsedMs: 250,
    );
    expect(attempt.status, 'ok');
    expect(attempt.statusCode, 200);
    expect(attempt.error, isNull);
    expect(attempt.attempt, 1);
    expect(attempt.startedAtMs, 1000);
    expect(attempt.elapsedMs, 250);
  });

  test('a provider failure keeps the status code it answered with', () {
    final attempt = describeCallAttempt(
      attempt: 2,
      startedAtMs: 0,
      elapsedMs: 10,
      error: dioWith(429),
    );
    expect(attempt.status, 'http_4xx');
    expect(attempt.statusCode, 429);
    expect(attempt.error, isNotNull);
  });

  test('5xx and 4xx are told apart', () {
    expect(callAttemptStatus(dioWith(503)), 'http_5xx');
    expect(callAttemptStatus(dioWith(400)), 'http_4xx');
  });

  test('a cancel is a cancel, not the status code it never got', () {
    final cancelled = DioException.requestCancelled(
      requestOptions: RequestOptions(path: '/v1/chat/completions'),
      reason: 'user stopped it',
    );
    expect(callAttemptStatus(cancelled), 'cancelled');
    expect(callAttemptStatusCode(cancelled), 0);
  });

  test('a timeout, a closed connection and a dead socket each say so', () {
    expect(callAttemptStatus(TimeoutException('idle')), 'timeout');
    expect(callAttemptStatus(const HttpException('closed')), 'connection_closed');
    expect(callAttemptStatus(const SocketException('no route')), 'socket_error');
  });

  test('a failure with no response, and anything unrecognised, carry code 0', () {
    expect(callAttemptStatus(dioWith(null)), 'error');
    expect(callAttemptStatusCode(dioWith(null)), 0);
    expect(callAttemptStatus(Exception('something else')), 'error');
    expect(callAttemptStatusCode(Exception('something else')), 0);
  });

  test('error text is bounded, so an HTML error page is not stored per attempt', () {
    final attempt = describeCallAttempt(
      attempt: 1,
      startedAtMs: 0,
      elapsedMs: 1,
      error: Exception('x' * 5000),
    );
    expect(attempt.error!.length, lessThanOrEqualTo(501));
    expect(attempt.error, endsWith('…'));
  });

  test('a short error is kept whole', () {
    expect(boundedAttemptError(Exception('brief')), isNot(endsWith('…')));
    expect(boundedAttemptError(Exception('brief')), contains('brief'));
  });
}
