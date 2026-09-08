import 'dart:async';

import 'package:dio/dio.dart';

import '../models/pipeline_settings.dart';
import '../models/extra_request_parameter.dart';
import 'aux_retry_runner.dart';
import 'idle_timeout_guard.dart';
import 'transport/chat_transport_request.dart';
import 'transport/transport_factory.dart';

/// Resolved auxiliary API configuration for a non-streaming LLM call.
class AuxApiConfig {
  final String endpoint;
  final String apiKey;
  final String model;
  final String protocol;
  final bool useResponsesApi;
  final List<ExtraRequestParameter> extraRequestParameters;

  const AuxApiConfig({
    required this.endpoint,
    required this.apiKey,
    required this.model,
    required this.protocol,
    this.useResponsesApi = false,
    this.extraRequestParameters = const [],
  });
}

/// Shared helper for auxiliary (non-streaming) LLM calls.
///
/// Provides transport (`callOnce`, `callOnceWithLog`, `callStreamWithLog`) and
/// timeout resolution. API config resolution is handled by callers:
/// - Studio services (cleaner, fact-checker, Ledger) use [StudioSlotResolver]
///   to resolve the Studio cleaner slot.
/// - MemoryBook services (drafts, dedup) resolve `MemoryBookApiSettings`
///   inline.
///
/// Usage:
/// ```dart
/// const client = AuxLlmClient();
/// final resolver = StudioSlotResolver();
/// final config = await resolver.resolve(
///   apiConfigId: studioConfig.cleanerApiConfigId,
///   modelOverride: pipeline.cleaner.postCleanerModel,
/// );
/// final raw = await client.callOnce(
///   config: config,
///   prompt: '...',
///   maxTokens: 1000,
///   temperature: 0.2,
///   timeoutMs: client.resolveCleanerTimeout(pipeline),
///   cancelToken: cancelToken,
/// );
/// ```
class AuxLlmClient {
  const AuxLlmClient();

  /// Resolves the post-cleaner timeout from settings.
  ///
  /// Uses the user-configured `postCleanerTimeoutMs` when set (> 0); otherwise
  /// falls back to an explicit 60000 ms default. The old silent fallback to
  /// `memoryPipeline.auxTimeoutMs` (a hidden field with no UI) was removed so
  /// the actual timeout is always visible and predictable.
  int resolveCleanerTimeout(PipelineSettings settings) {
    return settings.cleaner.postCleanerTimeoutMs > 0
        ? settings.cleaner.postCleanerTimeoutMs
        : 60000;
  }

  /// Resolves the ledger LLM timeout from settings.
  ///
  /// Resolution order:
  /// 1. `studioLedgerTimeoutMs` (> 0, with seconds→ms normalization for legacy
  ///    values < 1000).
  /// 2. `postCleanerTimeoutMs` (> 0) — the ledger shares the cleaner slot's
  ///    model/endpoint, so the user's cleaner-timeout setting also protects the
  ///    ledger call. The ledger has no dedicated UI timeout field.
  /// 3. Explicit 60000 ms default (same as the cleaner).
  ///
  /// The old silent fallback to `memoryPipeline.auxTimeoutMs` (a hidden field
  /// with no UI) was removed so the timeout the user sets for the cleaner also
  /// applies to the ledger.
  int resolveLedgerTimeout(PipelineSettings settings) {
    final configured = settings.ledger.studioLedgerTimeoutMs;
    if (configured > 0) {
      // Early UI builds edited this value as seconds while the field name stores
      // milliseconds. Treat small persisted values as seconds to avoid
      // accidental sub-second Ledger timeouts (for example, 180 → 180000).
      return configured < 1000 ? configured * 1000 : configured;
    }
    final cleanerTimeout = settings.cleaner.postCleanerTimeoutMs;
    if (cleanerTimeout > 0) return cleanerTimeout;
    return 60000;
  }

  /// Makes a single non-streaming LLM call and returns the raw text response.
  ///
  /// Retries on 5xx server errors (502/503/500) and timeouts using a 3-attempt
  /// backoff (1s/2s/4s) via [AuxRetryRunner]. Throws [TimeoutException] if
  /// all attempts time out. Throws [DioException] (cancel) if [cancelToken] is
  /// cancelled.
  ///
  /// Prefer [callOnceWithLog] when the caller wants the per-attempt log for
  /// the agentic operations UI.
  Future<String> callOnce({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
  }) async {
    final outcome = await callOnceWithLog(
      config: config,
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      timeoutMs: timeoutMs,
      cancelToken: cancelToken,
    );
    if (outcome.isOk && outcome.text != null) return outcome.text!;
    throw _descriptiveError(outcome);
  }

  /// Same as [callOnce] but returns a [AuxCallOutcome] with the per-attempt
  /// log so callers can record it in the agentic operations log.
  Future<AuxCallOutcome> callOnceWithLog({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
  }) async {
    if (config.endpoint.isEmpty || config.model.isEmpty) {
      throw Exception('Aux API not configured');
    }
    final runner = const AuxRetryRunner();
    return runner.run(
      cancelToken: cancelToken,
      attempt: (i) => _callOnce(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: cancelToken,
        omitReasoning: omitReasoning,
        omitReasoningEffort: omitReasoningEffort,
        requestReasoning: requestReasoning,
      ),
    );
  }

  /// Streaming variant of [callOnceWithLog]. Makes a streaming LLM call
  /// (`stream: true`) and invokes [onChunk] with the accumulated text on
  /// every delta. Returns the same [AuxCallOutcome] (final text = last
  /// accumulation).
  ///
  /// On retry, the accumulator resets and [onChunk] is called with the new
  /// attempt's accumulated text (starting from `''`). Callers that render the
  /// chunks into a chat bubble should reset their view on the first chunk of
  /// each new attempt — a simple way is to overwrite with the incoming
  /// accumulated text (which starts at `''` on a fresh attempt).
  ///
  /// Used by the POST-cleaner to stream its rewrite into the chat bubble
  /// instead of replacing the text in one shot. Reranker and auditor keep
  /// using [callOnceWithLog] (non-streaming) because they need the full
  Future<AuxCallOutcome> callStreamWithLog({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    void Function(String accumulatedText)? onChunk,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
  }) async {
    if (config.endpoint.isEmpty || config.model.isEmpty) {
      throw Exception('Aux API not configured');
    }
    final runner = const AuxRetryRunner();
    return runner.run(
      cancelToken: cancelToken,
      attempt: (i) => _callStream(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: cancelToken,
        onChunk: onChunk,
        omitReasoning: omitReasoning,
        omitReasoningEffort: omitReasoningEffort,
        requestReasoning: requestReasoning,
      ),
    );
  }

  /// Builds a descriptive exception from a non-ok [AuxCallOutcome] so the
  /// caller's `catch` block can fall back to the original text with a useful
  /// error message.
  Object _descriptiveError(AuxCallOutcome outcome) {
    if (outcome.attempts.isEmpty) return Exception('Aux call failed');
    final last = outcome.attempts.last;
    if (last.status == 'timeout') {
      return TimeoutException('Aux timed out after retries');
    }
    if (last.statusCode != 0) {
      return DioException(
        requestOptions: RequestOptions(path: ''),
        response: Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: last.statusCode,
        ),
        type: DioExceptionType.badResponse,
        message: last.error ?? 'HTTP ${last.statusCode}',
      );
    }
    return Exception(last.error ?? 'Aux call failed');
  }

  Future<String> _callOnce({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
  }) async {
    final completer = Completer<String>();
    final transport = pickChatTransport(config.protocol);

    // Idle timeout: cancel the timer on the first chunk (text OR reasoning)
    // so a long (but progressing) generation is never cut off. Mirrors
    // AgentStreamRunner's pattern.
    final guard = IdleTimeoutGuard(timeoutMs, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Aux call timed out (idle) after ${timeoutMs}ms'),
        );
      }
    });

    unawaited(
      transport.stream(
        request: ChatTransportRequest(
          endpoint: config.endpoint,
          apiKey: config.apiKey,
          model: config.model,
          messages: [
            {'role': 'user', 'content': prompt},
          ],
          maxTokens: maxTokens,
          temperature: temperature,
          topP: 1.0,
          stream: false,
          requestReasoning: requestReasoning,
          useResponsesApi: config.useResponsesApi,
          omitReasoning: omitReasoning,
          omitReasoningEffort: omitReasoningEffort,
          extraRequestParameters: config.extraRequestParameters,
        ),
        cancelToken: cancelToken,
        onUpdate: (delta, reasoningDelta) {
          if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
            guard.cancel();
          }
        },
        onComplete: (text, _, {rawResponseJson}) {
          guard.dispose();
          if (!completer.isCompleted) completer.complete(text);
        },
        onError: (error) {
          guard.dispose();
          if (!completer.isCompleted) completer.completeError(error);
        },
      ),
    );

    return completer.future.whenComplete(guard.dispose);
  }

  /// Streaming variant of [_callOnce]. Calls `transport.stream` with
  /// `stream: true` and forwards accumulated text to [onChunk] on every
  /// delta. Completes with the final accumulated text.
  Future<String> _callStream({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    void Function(String accumulatedText)? onChunk,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
  }) async {
    final completer = Completer<String>();
    final transport = pickChatTransport(config.protocol);
    final accumulated = StringBuffer();

    // Idle timeout: cancel the timer on the first chunk (text OR reasoning)
    // so a long (but progressing) generation is never cut off. Mirrors
    // AgentStreamRunner's pattern.
    final guard = IdleTimeoutGuard(timeoutMs, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Aux stream timed out (idle) after ${timeoutMs}ms'),
        );
      }
    });

    unawaited(
      transport.stream(
        request: ChatTransportRequest(
          endpoint: config.endpoint,
          apiKey: config.apiKey,
          model: config.model,
          messages: [
            {'role': 'user', 'content': prompt},
          ],
          maxTokens: maxTokens,
          temperature: temperature,
          topP: 1.0,
          stream: true,
          requestReasoning: requestReasoning,
          useResponsesApi: config.useResponsesApi,
          omitReasoning: omitReasoning,
          omitReasoningEffort: omitReasoningEffort,
          extraRequestParameters: config.extraRequestParameters,
        ),
        cancelToken: cancelToken,
        onUpdate: (delta, reasoningDelta) {
          if (delta.isNotEmpty) {
            guard.cancel();
            accumulated.write(delta);
            final text = accumulated.toString();
            if (onChunk != null && !completer.isCompleted) {
              try {
                onChunk(text);
              } catch (_) {
                // Callback errors must not abort the stream.
              }
            }
          } else if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
            guard.cancel();
          }
        },
        onComplete: (text, _, {rawResponseJson}) {
          guard.dispose();
          // Prefer the transport's aggregated text (it may have post-processing
          // like trimming or final newline normalization). Fall back to our
          // own accumulation if the transport returned empty.
          final finalText = text.isNotEmpty ? text : accumulated.toString();
          if (!completer.isCompleted) {
            if (onChunk != null && finalText != accumulated.toString()) {
              try {
                onChunk(finalText);
              } catch (_) {}
            }
            completer.complete(finalText);
          }
        },
        onError: (error) {
          guard.dispose();
          if (!completer.isCompleted) {
            // Flush any partially-accumulated text to the chunk callback so
            // callers that rely on the onChunk side-channel (e.g. the cleaner's
            // _lastStreamedText partial-save) can recover content that arrived
            // before the connection broke. Without this, a mid-stream close
            // after real content deltas would lose them silently.
            final partial = accumulated.toString();
            if (partial.isNotEmpty && onChunk != null) {
              try {
                onChunk(partial);
              } catch (_) {
                // Callback errors must not mask the real transport error.
              }
            }
            completer.completeError(error);
          }
        },
      ),
    );

    return completer.future.whenComplete(guard.dispose);
  }
}
