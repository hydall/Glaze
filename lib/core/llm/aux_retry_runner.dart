import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/agent_operation_record.dart';

/// Outcome of a retried auxiliary LLM call. Carries the final text result (when
/// successful) plus the per-attempt log so callers can record it in the
/// agentic operations log.
class AuxCallOutcome {
  /// Final status. `ok` only when [text] is non-null and the last attempt
  /// succeeded.
  final AgentOperationStatus status;

  /// Raw text returned by the LLM on the last successful attempt. Null on
  /// any failure.
  final String? text;

  /// Per-attempt log (1 entry per attempt, in order).
  final List<AgentOperationAttempt> attempts;

  /// Total elapsed millis across all attempts.
  final int totalElapsedMs;

  const AuxCallOutcome({
    required this.status,
    this.text,
    this.attempts = const [],
    this.totalElapsedMs = 0,
  });

  bool get isOk => status == AgentOperationStatus.ok;
}

/// Retry policy for [AuxRetryRunner]. Default: 3 attempts, 1s/2s/4s
/// backoff, retries only on 5xx and TimeoutException.
class AuxRetryPolicy {
  final int maxAttempts;
  final List<Duration> backoffDelays;
  final bool retryOnTimeout;

  const AuxRetryPolicy({
    this.maxAttempts = 3,
    this.backoffDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.retryOnTimeout = true,
  });

  /// Whether an exception should trigger a retry (given the attempt number).
  /// Retries 5xx server errors, timeouts, and transient connection errors
  /// (connection closed mid-stream, socket reset); 4xx and other errors fail
  /// fast.
  bool shouldRetry(Object error, int attempt) {
    if (attempt >= maxAttempts - 1) return false;
    if (error is TimeoutException) return retryOnTimeout;
    if (error is HttpException) return true; // connection closed mid-stream
    if (error is SocketException) return true; // TCP reset / refused
    if (error is DioException) {
      final code = error.response?.statusCode ?? 0;
      if (code >= 500 && code < 600) return true;
    }
    return false;
  }

  /// Backoff delay before attempt [attempt] (0-based). Attempt 0 is the first
  /// call (no delay). Attempt 1 waits [backoffDelays[0]], etc.
  Duration delayBefore(int attempt) {
    if (attempt <= 0) return Duration.zero;
    final idx = attempt - 1;
    if (idx < backoffDelays.length) return backoffDelays[idx];
    return backoffDelays.isEmpty ? Duration.zero : backoffDelays.last;
  }
}

/// Runs a single-attempt LLM call under a retry policy and produces a
/// [AuxCallOutcome] with the per-attempt log. Used by the shared
/// [AuxLlmClient] (post-cleaner,
/// agentic search/write) so retry behaviour is uniform and visible.
class AuxRetryRunner {
  final AuxRetryPolicy policy;

  const AuxRetryRunner({this.policy = const AuxRetryPolicy()});

  /// Runs [attempt] under the retry policy. [attempt] must throw on failure
  /// (will be caught and logged as an attempt) and return the raw text on
  /// success. [cancelToken] is checked between attempts; if cancelled, the
  /// loop exits early with [AgentOperationStatus.aborted].
  Future<AuxCallOutcome> run({
    required Future<String> Function(int attempt) attempt,
    CancelToken? cancelToken,
  }) async {
    final sw = Stopwatch()..start();
    final attemptsLog = <AgentOperationAttempt>[];
    for (var i = 0; i < policy.maxAttempts; i++) {
      if (cancelToken?.isCancelled ?? false) {
        attemptsLog.add(_logCancelled(i, sw.elapsedMilliseconds));
        return _finish(
          AgentOperationStatus.aborted,
          attemptsLog,
          sw.elapsedMilliseconds,
        );
      }
      final delay = policy.delayBefore(i);
      if (delay != Duration.zero) {
        debugPrint(
          '[AuxRetry] backing off ${delay.inMilliseconds}ms before attempt ${i + 1}',
        );
        try {
          await Future<void>.delayed(delay);
        } catch (_) {
          // Cancellation during delay → aborted.
          attemptsLog.add(_logCancelled(i, sw.elapsedMilliseconds));
          return _finish(
            AgentOperationStatus.aborted,
            attemptsLog,
            sw.elapsedMilliseconds,
          );
        }
        if (cancelToken?.isCancelled ?? false) {
          attemptsLog.add(_logCancelled(i, sw.elapsedMilliseconds));
          return _finish(
            AgentOperationStatus.aborted,
            attemptsLog,
            sw.elapsedMilliseconds,
          );
        }
      }

      final attemptSw = Stopwatch()..start();
      try {
        final text = await attempt(i);
        attemptSw.stop();
        attemptsLog.add(
          AgentOperationAttempt(
            attempt: i + 1,
            statusCode: 200,
            status: 'ok',
            startedAtMs: DateTime.now().millisecondsSinceEpoch,
            elapsedMs: attemptSw.elapsedMilliseconds,
          ),
        );
        return _finishOk(text, attemptsLog, sw.elapsedMilliseconds);
      } catch (e) {
        attemptSw.stop();
        attemptsLog.add(_logError(i, e, attemptSw.elapsedMilliseconds));
        if (cancelToken?.isCancelled ?? false) {
          return _finish(
            AgentOperationStatus.aborted,
            attemptsLog,
            sw.elapsedMilliseconds,
          );
        }
        if (!policy.shouldRetry(e, i)) {
          return _finish(_statusFor(e), attemptsLog, sw.elapsedMilliseconds);
        }
      }
    }
    return _finish(
      AgentOperationStatus.error,
      attemptsLog,
      sw.elapsedMilliseconds,
    );
  }

  static AuxCallOutcome _finishOk(
    String text,
    List<AgentOperationAttempt> attempts,
    int totalMs,
  ) {
    return AuxCallOutcome(
      status: AgentOperationStatus.ok,
      text: text,
      attempts: List.unmodifiable(attempts),
      totalElapsedMs: totalMs,
    );
  }

  static AuxCallOutcome _finish(
    AgentOperationStatus status,
    List<AgentOperationAttempt> attempts,
    int totalMs,
  ) {
    return AuxCallOutcome(
      status: status,
      attempts: List.unmodifiable(attempts),
      totalElapsedMs: totalMs,
    );
  }

  static AgentOperationStatus _statusFor(Object error) {
    if (error is TimeoutException) return AgentOperationStatus.timeout;
    if (error is HttpException || error is SocketException) {
      return AgentOperationStatus.error;
    }
    if (error is DioException) {
      if (CancelToken.isCancel(error)) return AgentOperationStatus.aborted;
      final code = error.response?.statusCode ?? 0;
      if (code >= 500 && code < 600) return AgentOperationStatus.httpError;
      if (code >= 400 && code < 500) return AgentOperationStatus.httpError;
    }
    return AgentOperationStatus.error;
  }

  static AgentOperationAttempt _logError(int attempt, Object e, int elapsedMs) {
    int code = 0;
    String statusLabel = 'error';
    if (e is TimeoutException) {
      statusLabel = 'timeout';
    } else if (e is HttpException) {
      statusLabel = 'connection_closed';
    } else if (e is SocketException) {
      statusLabel = 'socket_error';
    } else if (e is DioException) {
      code = e.response?.statusCode ?? 0;
      if (CancelToken.isCancel(e)) {
        statusLabel = 'cancelled';
      } else if (code >= 500 && code < 600) {
        statusLabel = 'http_5xx';
      } else if (code >= 400 && code < 500) {
        statusLabel = 'http_4xx';
      }
    }
    final errText = e.toString();
    final trimmed = errText.length > 500
        ? '${errText.substring(0, 500)}…'
        : errText;
    return AgentOperationAttempt(
      attempt: attempt + 1,
      statusCode: code,
      status: statusLabel,
      error: trimmed,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      elapsedMs: elapsedMs,
    );
  }

  static AgentOperationAttempt _logCancelled(int attempt, int elapsedMs) {
    return AgentOperationAttempt(
      attempt: attempt + 1,
      statusCode: 0,
      status: 'cancelled',
      error: 'cancelled',
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      elapsedMs: elapsedMs,
    );
  }
}
