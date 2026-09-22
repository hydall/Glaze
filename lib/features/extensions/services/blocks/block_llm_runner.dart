import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/llm/idle_timeout_guard.dart';
import '../../../../core/llm/transport/call_attempt_outcome.dart';
import '../../../../core/llm/transport/chat_transport.dart';
import '../../../../core/llm/transport/chat_transport_request.dart';
import '../../../../core/llm/transport/llm_call_event.dart';
import '../../../../core/llm/transport/llm_capture_context.dart';
import '../../../../core/llm/transport/transport_factory.dart';
import '../../../../core/models/api_config.dart';

typedef BlockTransportPicker = ChatTransport Function(String protocol);

/// Runs one ext-block generation over the connection's own protocol transport.
///
/// Extracted from [InfoBlockService] because the timeout discipline is the
/// half of an ext-block generation worth testing on its own: the service around
/// it needs a provider container and a database, a transport does not.
///
/// What this owns, and why the chat's generation owns the same two things:
/// - the deadline is the connection's `firstChunkTimeoutMs`, measured from the
///   last sign of life rather than from the start, so a slow-but-progressing
///   reply is never cut off;
/// - `receiveTimeoutMs: 0` takes the ceiling off the transport's Dio instance
///   so that deadline is the only one. Left to the transport, a block was
///   capped at whatever that instance carried — 120s for the OpenAI-shaped
///   protocols, 180s for Anthropic and Gemini — no matter what the reader had
///   configured, and a provider that accepted the request and then went silent
///   surfaced a raw receive timeout instead of the block's own error.
class BlockLlmRunner {
  const BlockLlmRunner({this.transportPicker = pickChatTransport});

  final BlockTransportPicker transportPicker;

  /// Fallback deadline when the connection carries no `firstChunkTimeoutMs`.
  static const int fallbackTimeoutMs = 60000;

  /// Generates the block's raw text.
  ///
  /// Returns null when [cancelToken] was cancelled — that is the reader
  /// pressing stop, which the handlers render as "stopped" rather than as a
  /// failure. Throws otherwise: a [TimeoutException] when nothing arrived
  /// inside the deadline, and whatever the transport reported for everything
  /// else, so the panel can show it through the shared `formatError`.
  Future<String?> run({
    required ApiConfig apiConfig,
    required List<Map<String, dynamic>> messages,
    String? model,
    required bool stream,
    String? charName,
    String? userName,
    CancelToken? cancelToken,
    void Function(String accumulated)? onStreamUpdate,
    LlmCaptureContext? captureContext,
  }) async {
    final idleTimeoutMs = apiConfig.firstChunkTimeoutMs > 0
        ? apiConfig.firstChunkTimeoutMs
        : fallbackTimeoutMs;

    // One outcome per call, recorded on the same `callId` the request capture
    // carries. Without it a block's request shows up in the inspector with no
    // reply beside it, unlike every other stage. `onComplete` and `onError`
    // are not exclusive on every transport, so the first write wins.
    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    var outcomeRecorded = false;
    void recordOutcome({String? responseText, Object? error}) {
      if (captureContext == null || outcomeRecorded) return;
      outcomeRecorded = true;
      unawaited(
        LlmCallEventCapture.record(
          LlmCallEvent.transport(
            context: captureContext,
            attempt: describeCallAttempt(
              attempt: 1,
              startedAtMs: startedAtMs,
              elapsedMs: DateTime.now().millisecondsSinceEpoch - startedAtMs,
              error: error,
            ),
            responseText: responseText,
          ),
        ),
      );
    }

    // The timeout cancels a token of its own, never the caller's: a cancelled
    // caller token means the reader pressed stop, and that is a different
    // outcome for the block than a provider that never answered.
    final requestToken = CancelToken();
    final callerCancelled = cancelToken?.whenCancel;
    if (callerCancelled != null) {
      unawaited(
        callerCancelled.then((error) {
          if (!requestToken.isCancelled) requestToken.cancel(error);
        }),
      );
    }

    var timedOut = false;
    final idleGuard = IdleTimeoutGuard(idleTimeoutMs, () {
      timedOut = true;
      requestToken.cancel(
        'Ext block first-chunk timeout after ${idleTimeoutMs}ms',
      );
    });

    final completer = Completer<String>();
    final buffer = StringBuffer();

    try {
      await transportPicker(apiConfig.protocol).stream(
        request: ChatTransportRequest.fromApiConfig(
          apiConfig,
          model: model,
          messages: messages,
          stream: stream,
          receiveTimeoutMs: 0,
          charName: charName,
          userName: userName,
          captureContext: captureContext,
        ),
        cancelToken: requestToken,
        onUpdate: (delta, reasoningDelta) {
          // Reasoning-only output is a sign of life too: a thinking model must
          // not be cut off just because no visible text has arrived yet.
          if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
            idleGuard.cancel();
          }
          if (onStreamUpdate == null || delta.isEmpty) return;
          buffer.write(delta);
          onStreamUpdate(buffer.toString());
        },
        onComplete: (text, reasoning, {rawResponseJson}) {
          idleGuard.dispose();
          recordOutcome(responseText: text);
          if (!completer.isCompleted) completer.complete(text);
        },
        onError: (error) {
          idleGuard.dispose();
          recordOutcome(error: error);
          if (!completer.isCompleted) completer.completeError(error);
        },
      );

      if (timedOut) throw _timeout(idleTimeoutMs);
      // A transport that returns without having called either callback would
      // otherwise leave the block spinning on a future nobody completes.
      if (!completer.isCompleted) {
        throw StateError('Ext block transport ended without a result');
      }
      return await completer.future;
    } catch (e) {
      if (timedOut) {
        recordOutcome(error: _timeout(idleTimeoutMs));
        throw _timeout(idleTimeoutMs);
      }
      if (cancelToken?.isCancelled == true ||
          (e is DioException && CancelToken.isCancel(e))) {
        recordOutcome(error: e);
        return null;
      }
      recordOutcome(error: e);
      debugPrint('[BlockLlmRunner] LLM call failed: $e');
      rethrow;
    } finally {
      idleGuard.dispose();
    }
  }

  TimeoutException _timeout(int idleTimeoutMs) => TimeoutException(
    'Ext block generation timed out after ${idleTimeoutMs}ms',
  );
}
