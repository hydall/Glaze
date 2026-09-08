import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';

void main() {
  group('AuxRetryRunner', () {
    test('returns ok on first success', () async {
      final runner = const AuxRetryRunner();
      final outcome = await runner.run(attempt: (_) async => 'hello');
      expect(outcome.isOk, isTrue);
      expect(outcome.text, 'hello');
      expect(outcome.attempts.length, 1);
      expect(outcome.attempts.first.status, 'ok');
      expect(outcome.attempts.first.attempt, 1);
    });

    test('retries on 5xx DioException up to maxAttempts', () async {
      final runner = const AuxRetryRunner(
        policy: AuxRetryPolicy(
          maxAttempts: 3,
          backoffDelays: [Duration.zero, Duration.zero, Duration.zero],
        ),
      );
      var calls = 0;
      final outcome = await runner.run(
        attempt: (_) async {
          calls++;
          if (calls < 3) {
            throw DioException(
              requestOptions: RequestOptions(path: ''),
              response: Response(
                requestOptions: RequestOptions(path: ''),
                statusCode: 502,
              ),
              type: DioExceptionType.badResponse,
            );
          }
          return 'recovered';
        },
      );
      expect(outcome.isOk, isTrue);
      expect(outcome.text, 'recovered');
      expect(outcome.attempts.length, 3);
      expect(outcome.attempts[0].status, 'http_5xx');
      expect(outcome.attempts[0].statusCode, 502);
      expect(outcome.attempts[1].status, 'http_5xx');
      expect(outcome.attempts[2].status, 'ok');
      expect(calls, 3);
    });

    test('fails fast on 4xx (no retry)', () async {
      final runner = const AuxRetryRunner();
      var calls = 0;
      final outcome = await runner.run(
        attempt: (_) async {
          calls++;
          throw DioException(
            requestOptions: RequestOptions(path: ''),
            response: Response(
              requestOptions: RequestOptions(path: ''),
              statusCode: 401,
            ),
            type: DioExceptionType.badResponse,
          );
        },
      );
      expect(outcome.isOk, isFalse);
      expect(outcome.status, AgentOperationStatus.httpError);
      expect(outcome.attempts.length, 1);
      expect(outcome.attempts.first.statusCode, 401);
      expect(calls, 1);
    });

    test('retries on TimeoutException when retryOnTimeout=true', () async {
      final runner = const AuxRetryRunner(
        policy: AuxRetryPolicy(
          maxAttempts: 2,
          backoffDelays: [Duration.zero],
          retryOnTimeout: true,
        ),
      );
      var calls = 0;
      final outcome = await runner.run(
        attempt: (_) async {
          calls++;
          if (calls == 1) throw TimeoutException('timed out');
          return 'ok-after-retry';
        },
      );
      expect(outcome.isOk, isTrue);
      expect(outcome.text, 'ok-after-retry');
      expect(outcome.attempts.length, 2);
      expect(outcome.attempts.first.status, 'timeout');
      expect(outcome.attempts.last.status, 'ok');
    });

    test(
      'does NOT retry on TimeoutException when retryOnTimeout=false',
      () async {
        final runner = const AuxRetryRunner(
          policy: AuxRetryPolicy(retryOnTimeout: false),
        );
        final outcome = await runner.run(
          attempt: (_) async => throw TimeoutException('timed out'),
        );
        expect(outcome.isOk, isFalse);
        expect(outcome.status, AgentOperationStatus.timeout);
        expect(outcome.attempts.length, 1);
      },
    );

    test('exits early with aborted when cancelToken cancelled', () async {
      final runner = const AuxRetryRunner();
      final token = CancelToken();
      token.cancel();
      final outcome = await runner.run(
        cancelToken: token,
        attempt: (_) async => 'should-not-run',
      );
      expect(outcome.status, AgentOperationStatus.aborted);
      expect(outcome.attempts.length, 1);
      expect(outcome.attempts.first.status, 'cancelled');
    });

    test('stops retrying after maxAttempts on persistent 5xx', () async {
      final runner = const AuxRetryRunner(
        policy: AuxRetryPolicy(
          maxAttempts: 3,
          backoffDelays: [Duration.zero, Duration.zero, Duration.zero],
        ),
      );
      var calls = 0;
      final outcome = await runner.run(
        attempt: (_) async {
          calls++;
          throw DioException(
            requestOptions: RequestOptions(path: ''),
            response: Response(
              requestOptions: RequestOptions(path: ''),
              statusCode: 503,
            ),
            type: DioExceptionType.badResponse,
          );
        },
      );
      expect(outcome.isOk, isFalse);
      expect(outcome.status, AgentOperationStatus.httpError);
      expect(outcome.attempts.length, 3);
      expect(calls, 3);
    });
  });

  group('AgentOperationRecord', () {
    test('tileLabel includes attempt count when retried', () {
      final rec = AgentOperationRecord(
        id: 'r1',
        kind: AgentOperationKind.postCleaner,
        status: AgentOperationStatus.ok,
        attempts: [
          const AgentOperationAttempt(
            attempt: 1,
            statusCode: 502,
            status: 'http_5xx',
            startedAtMs: 0,
            elapsedMs: 100,
          ),
          const AgentOperationAttempt(
            attempt: 2,
            statusCode: 200,
            status: 'ok',
            startedAtMs: 100,
            elapsedMs: 200,
          ),
        ],
        totalElapsedMs: 300,
        startedAtMs: 0,
        finishedAtMs: 300,
      );
      expect(rec.wasRetried, isTrue);
      expect(rec.attemptCount, 2);
      expect(rec.tileLabel, 'POST-cleaner · ok · 2 attempts · 300ms');
    });

    test('tileLabel omits attempt count when not retried', () {
      final rec = AgentOperationRecord(
        id: 'r2',
        kind: AgentOperationKind.postCleaner,
        status: AgentOperationStatus.ok,
        attempts: [
          const AgentOperationAttempt(
            attempt: 1,
            statusCode: 200,
            status: 'ok',
            startedAtMs: 0,
            elapsedMs: 50,
          ),
        ],
        totalElapsedMs: 50,
        startedAtMs: 0,
        finishedAtMs: 50,
      );
      expect(rec.wasRetried, isFalse);
      expect(rec.tileLabel, 'POST-cleaner · ok · 50ms');
    });

    test('toJson/fromJson roundtrip preserves all fields', () {
      final rec = AgentOperationRecord(
        id: 'r3',
        kind: AgentOperationKind.studioLedger,
        status: AgentOperationStatus.httpError,
        sessionId: 's1',
        messageId: 'm1',
        attempts: const [
          AgentOperationAttempt(
            attempt: 1,
            statusCode: 500,
            status: 'http_5xx',
            error: 'Internal Server Error',
            startedAtMs: 1000,
            elapsedMs: 50,
          ),
        ],
        totalElapsedMs: 50,
        model: 'gpt-4o',
        endpoint: 'https://api.example.com',
        summary: 'failed: 500',
        startedAtMs: 1000,
        finishedAtMs: 1050,
        canRegenerate: true,
      );
      final json = rec.toJson();
      final restored = AgentOperationRecord.fromJson(json);
      expect(restored.id, 'r3');
      expect(restored.kind, AgentOperationKind.studioLedger);
      expect(restored.status, AgentOperationStatus.httpError);
      expect(restored.sessionId, 's1');
      expect(restored.messageId, 'm1');
      expect(restored.attempts.length, 1);
      expect(restored.attempts.first.statusCode, 500);
      expect(restored.attempts.first.error, 'Internal Server Error');
      expect(restored.totalElapsedMs, 50);
      expect(restored.model, 'gpt-4o');
      expect(restored.canRegenerate, isTrue);
    });

    test('Ledger reconciliation kind survives serialization', () {
      final record = AgentOperationRecord(
        id: 'reconcile-1',
        kind: AgentOperationKind.studioLedgerReconciliation,
        status: AgentOperationStatus.ok,
        startedAtMs: 1000,
        finishedAtMs: 1050,
      );

      final restored = AgentOperationRecord.fromJson(record.toJson());
      expect(restored.kind, AgentOperationKind.studioLedgerReconciliation);
      expect(restored.kind.label, 'Studio Ledger reconciliation');
    });

    test('status.isFailure excludes ok/aborted/disabled', () {
      expect(AgentOperationStatus.ok.isFailure, isFalse);
      expect(AgentOperationStatus.aborted.isFailure, isFalse);
      expect(AgentOperationStatus.disabled.isFailure, isFalse);
      expect(AgentOperationStatus.timeout.isFailure, isTrue);
      expect(AgentOperationStatus.httpError.isFailure, isTrue);
      expect(AgentOperationStatus.error.isFailure, isTrue);
      expect(AgentOperationStatus.invalidOutput.isFailure, isTrue);
    });
  });

  group('AuxRetryPolicy', () {
    test('default policy has 3 attempts and 1s/2s/4s backoff', () {
      const policy = AuxRetryPolicy();
      expect(policy.maxAttempts, 3);
      expect(policy.backoffDelays.length, 3);
      expect(policy.backoffDelays[0], const Duration(seconds: 1));
      expect(policy.backoffDelays[1], const Duration(seconds: 2));
      expect(policy.backoffDelays[2], const Duration(seconds: 4));
    });

    test('delayBefore: no delay for first attempt', () {
      const policy = AuxRetryPolicy();
      expect(policy.delayBefore(0), Duration.zero);
    });

    test('delayBefore: returns backoff for subsequent attempts', () {
      const policy = AuxRetryPolicy();
      expect(policy.delayBefore(1), const Duration(seconds: 1));
      expect(policy.delayBefore(2), const Duration(seconds: 2));
    });

    test('shouldRetry: false for 4xx', () {
      const policy = AuxRetryPolicy();
      final err = DioException(
        requestOptions: RequestOptions(path: ''),
        response: Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 404,
        ),
        type: DioExceptionType.badResponse,
      );
      expect(policy.shouldRetry(err, 0), isFalse);
    });

    test('shouldRetry: false on last attempt', () {
      const policy = AuxRetryPolicy();
      final err = DioException(
        requestOptions: RequestOptions(path: ''),
        response: Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 502,
        ),
        type: DioExceptionType.badResponse,
      );
      expect(policy.shouldRetry(err, 2), isFalse);
    });
  });
}
