import 'dart:async';

import 'package:dio/dio.dart';

import '../models/pipeline_settings.dart';
import '../models/extra_request_parameter.dart';
import '../utils/id_generator.dart';
import 'aux_retry_runner.dart';
import 'idle_timeout_guard.dart';
import 'transport/chat_transport.dart';
import 'transport/chat_transport_request.dart';
import 'transport/llm_capture_context.dart';
import 'transport/llm_call_event.dart';
import 'transport/transport_factory.dart';

typedef AuxTransportPicker = ChatTransport Function(String protocol);

/// Receives the provider's own response fields for a non-streaming aux call:
/// the separate reasoning stream (when the model emitted one) and the raw JSON
/// payload. Callers use them for diagnostics when the assistant text alone does
/// not explain a failure.
typedef AuxRawResponseSink =
    void Function(String? reasoning, String? rawResponseJson);

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
///   apiConfigId: studioPreset.cleanerApiConfigId,
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
  final AuxTransportPicker transportPicker;
  final AuxRetryPolicy retryPolicy;

  const AuxLlmClient({
    this.transportPicker = pickChatTransport,
    this.retryPolicy = const AuxRetryPolicy(),
  });

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
  ///
  /// Pass [messages] instead of [prompt] for a call that needs a full chat
  /// (a `system` prompt plus the user turn) rather than a single user message.
  Future<String> callOnce({
    required AuxApiConfig config,
    String prompt = '',
    List<Map<String, String>>? messages,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
    AuxRawResponseSink? onRawResponse,
  }) async {
    final outcome = await callOnceWithLog(
      config: config,
      prompt: prompt,
      messages: messages,
      maxTokens: maxTokens,
      temperature: temperature,
      timeoutMs: timeoutMs,
      cancelToken: cancelToken,
      captureContext: captureContext,
      onRawResponse: onRawResponse,
    );
    if (outcome.isOk && outcome.text != null) return outcome.text!;
    throw _descriptiveError(outcome);
  }

  /// Same as [callOnce] but returns a [AuxCallOutcome] with the per-attempt
  /// log so callers can record it in the agentic operations log.
  Future<AuxCallOutcome> callOnceWithLog({
    required AuxApiConfig config,
    String prompt = '',
    List<Map<String, String>>? messages,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
    bool omitTopP = true,
    LlmCaptureContext? captureContext,
    AuxRawResponseSink? onRawResponse,
    FutureOr<void> Function(int attempt, int maxAttempts)? onAttemptStart,
  }) async {
    if (config.endpoint.isEmpty || config.model.isEmpty) {
      throw Exception('Aux API not configured');
    }
    if (messages == null && prompt.isEmpty) {
      throw ArgumentError('Provide a prompt or messages');
    }
    final runner = AuxRetryRunner(policy: retryPolicy);
    final identifiedContext = _identifiedContext(captureContext);
    return runner.run(
      cancelToken: cancelToken,
      captureContext: identifiedContext,
      onAttemptStart: onAttemptStart,
      onAttemptComplete: identifiedContext == null
          ? null
          : (attempt, responseText) => LlmCallEventCapture.record(
              LlmCallEvent.transport(
                context: identifiedContext,
                attempt: attempt,
                responseText: responseText,
              ),
            ),
      attemptWithCancelToken: (i, attemptCancelToken) => _callOnce(
        config: config,
        prompt: prompt,
        messages: messages,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: attemptCancelToken,
        omitReasoning: omitReasoning,
        omitReasoningEffort: omitReasoningEffort,
        requestReasoning: requestReasoning,
        omitTopP: omitTopP,
        captureContext: identifiedContext?.withAttempt(i + 1),
        onRawResponse: onRawResponse,
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
    LlmCaptureContext? captureContext,
  }) async {
    if (config.endpoint.isEmpty || config.model.isEmpty) {
      throw Exception('Aux API not configured');
    }
    final runner = AuxRetryRunner(policy: retryPolicy);
    final identifiedContext = _identifiedContext(captureContext);
    return runner.run(
      cancelToken: cancelToken,
      captureContext: identifiedContext,
      onAttemptComplete: identifiedContext == null
          ? null
          : (attempt, responseText) => LlmCallEventCapture.record(
              LlmCallEvent.transport(
                context: identifiedContext,
                attempt: attempt,
                responseText: responseText,
              ),
            ),
      attemptWithCancelToken: (i, attemptCancelToken) => _callStream(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: attemptCancelToken,
        onChunk: onChunk,
        omitReasoning: omitReasoning,
        omitReasoningEffort: omitReasoningEffort,
        requestReasoning: requestReasoning,
        captureContext: identifiedContext?.withAttempt(i + 1),
      ),
    );
  }

  static LlmCaptureContext? _identifiedContext(LlmCaptureContext? context) {
    if (context == null) return null;
    return context.withCallIdentity(
      pipelineRunId: context.pipelineRunId ?? 'llm-pipeline-${generateId()}',
      callId: context.callId ?? 'llm-call-${generateId()}',
    );
  }

  /// Builds a descriptive exception from a non-ok [AuxCallOutcome] so the
  /// caller's `catch` block can fall back to the original text with a useful
  /// error message.
  ///
  /// The last attempt's own exception is preferred when there is one: a
  /// [DioException] still carries the provider's response body, which
  /// `formatError()` renders as `HTTP 400: <provider message>` instead of the
  /// generic status text a reconstructed exception would produce.
  Object _descriptiveError(AuxCallOutcome outcome) {
    final original = outcome.lastError;
    if (original != null) return original;
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
    String prompt = '',
    List<Map<String, String>>? messages,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
    bool omitTopP = true,
    LlmCaptureContext? captureContext,
    AuxRawResponseSink? onRawResponse,
  }) async {
    final transport = transportPicker(config.protocol);
    String? result;
    Object? transportError;
    var callbackReceived = false;
    var acceptingCallbacks = true;
    var timedOut = false;

    // Idle timeout: cancel the timer on the first chunk (text OR reasoning)
    // so a long (but progressing) generation is never cut off. Mirrors
    // AgentStreamRunner's pattern. `timeoutMs <= 0` means the caller owns the
    // deadline itself (a single long request whose answer only arrives at the
    // end, such as a lorebook rebuild) — no guard is armed at all.
    final guard = timeoutMs > 0
        ? IdleTimeoutGuard(timeoutMs, () {
            if (acceptingCallbacks) {
              timedOut = true;
              acceptingCallbacks = false;
              cancelToken?.cancel('Aux call idle timeout');
            }
          })
        : null;

    try {
      // Deliberately await the transport itself, not a callback completer. On
      // timeout the request is cancelled above and fully drained here before
      // this attempt may return and the retry runner may start another one.
      await transport.stream(
        request: ChatTransportRequest(
          endpoint: config.endpoint,
          apiKey: config.apiKey,
          model: config.model,
          messages:
              messages ??
              [
                {'role': 'user', 'content': prompt},
              ],
          maxTokens: maxTokens,
          temperature: temperature,
          topP: 1.0,
          // Aux calls pin their own temperature and deliberately don't steer
          // top_p. Say so explicitly — the transports no longer treat 1.0 as
          // "unset".
          omitTopP: omitTopP,
          stream: false,
          requestReasoning: requestReasoning,
          useResponsesApi: config.useResponsesApi,
          omitReasoning: omitReasoning,
          omitReasoningEffort: omitReasoningEffort,
          extraRequestParameters: config.extraRequestParameters,
          // 0 also disables the transport-level HTTP receive timeout, so a
          // caller that opted out of the idle guard is not cut off by Dio
          // instead.
          receiveTimeoutMs: timeoutMs > 0 ? timeoutMs : 0,
          captureContext: captureContext,
        ),
        cancelToken: cancelToken,
        onUpdate: (delta, reasoningDelta) {
          if (!acceptingCallbacks || cancelToken?.isCancelled == true) return;
          if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
            guard?.cancel();
          }
        },
        onComplete: (text, reasoning, {rawResponseJson}) {
          guard?.dispose();
          if (!acceptingCallbacks || cancelToken?.isCancelled == true) return;
          callbackReceived = true;
          result = text;
          // Handed to the caller even on a "successful" empty answer: a build
          // that parses the text needs the provider payload to explain why
          // there was nothing in it.
          onRawResponse?.call(reasoning, rawResponseJson);
        },
        onError: (error) {
          guard?.dispose();
          if (!acceptingCallbacks || cancelToken?.isCancelled == true) return;
          callbackReceived = true;
          transportError = error;
        },
      );
    } catch (e) {
      if (acceptingCallbacks) transportError = e;
    } finally {
      acceptingCallbacks = false;
      guard?.dispose();
    }
    if (timedOut) {
      throw TimeoutException('Aux call timed out (idle) after ${timeoutMs}ms');
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    if (transportError != null) throw transportError!;
    if (!callbackReceived) {
      throw StateError('Aux transport ended without a result');
    }
    return result ?? '';
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
    LlmCaptureContext? captureContext,
  }) async {
    final transport = transportPicker(config.protocol);
    final accumulated = StringBuffer();
    String? result;
    Object? transportError;
    var callbackReceived = false;
    var acceptingCallbacks = true;
    var timedOut = false;

    // Idle timeout: cancel the timer on the first chunk (text OR reasoning)
    // so a long (but progressing) generation is never cut off. Mirrors
    // AgentStreamRunner's pattern.
    final guard = IdleTimeoutGuard(timeoutMs, () {
      if (acceptingCallbacks) {
        timedOut = true;
        acceptingCallbacks = false;
        cancelToken?.cancel('Aux stream idle timeout');
      }
    });

    try {
      await transport.stream(
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
          // See `_callOnce` — top_p is intentionally not steered here.
          omitTopP: true,
          stream: true,
          requestReasoning: requestReasoning,
          useResponsesApi: config.useResponsesApi,
          omitReasoning: omitReasoning,
          omitReasoningEffort: omitReasoningEffort,
          extraRequestParameters: config.extraRequestParameters,
          receiveTimeoutMs: timeoutMs,
          captureContext: captureContext,
        ),
        cancelToken: cancelToken,
        onUpdate: (delta, reasoningDelta) {
          if (!acceptingCallbacks || cancelToken?.isCancelled == true) return;
          if (delta.isNotEmpty) {
            guard.cancel();
            accumulated.write(delta);
            final text = accumulated.toString();
            if (onChunk != null) {
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
          if (acceptingCallbacks && cancelToken?.isCancelled != true) {
            if (onChunk != null && finalText != accumulated.toString()) {
              try {
                onChunk(finalText);
              } catch (_) {}
            }
            callbackReceived = true;
            result = finalText;
          }
        },
        onError: (error) {
          guard.dispose();
          if (acceptingCallbacks && cancelToken?.isCancelled != true) {
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
            callbackReceived = true;
            transportError = error;
          }
        },
      );
    } catch (e) {
      if (acceptingCallbacks) transportError = e;
    } finally {
      acceptingCallbacks = false;
      guard.dispose();
    }
    if (timedOut) {
      throw TimeoutException(
        'Aux stream timed out (idle) after ${timeoutMs}ms',
      );
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    if (transportError != null) throw transportError!;
    if (!callbackReceived) {
      throw StateError('Aux stream transport ended without a result');
    }
    return result ?? accumulated.toString();
  }
}
