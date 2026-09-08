import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/history_assembler.dart';
import '../../../core/llm/idle_timeout_guard.dart';
import '../../../core/llm/macro_engine.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../providers/prompt_build_providers.dart';
import '../../../core/llm/stream_accumulator.dart';
import '../../../core/llm/tokenizer.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/transport/transport_factory.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/services/preset_defaults.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../core/state/preset_resolution.dart';
import '../../../core/utils/id_generator.dart';

/// Result of resolving whether impersonation can run for the current context.
enum ImpersonationOutcome { ok, notConfigured, aborted, failed }

/// Runs an "impersonation" generation, mirroring hydall/Glaze: the LLM writes
/// the user's next message using the preset's `impersonationPrompt` and the
/// streamed output is fed back into the compose box (never appended to the
/// chat as an assistant message).
///
/// Unlike the main [StreamGenerationService] this path is intentionally
/// message-less — it appends a synthetic user turn carrying the impersonation
/// instruction to a throwaway session copy, streams the completion, and reports
/// the running text through [onDelta].
class ImpersonationService {
  final Ref _ref;
  final String _charId;
  final bool Function() _isAborted;

  ImpersonationService({
    required this._ref,
    required this._charId,
    required this._isAborted,
  });

  /// Resolves the effective impersonation prompt for [sessionId], or null when
  /// it is empty/unset (the caller should then prompt the user to configure it,
  /// matching Glaze's "Impersonation prompt is empty" bottom sheet).
  String? resolveImpersonationPrompt(String? sessionId) {
    final preset = _ref.read(
      effectivePresetForChatProvider((charId: _charId, sessionId: sessionId)),
    );
    final prompt = preset?.impersonationPrompt;
    if (prompt == null || prompt.trim().isEmpty) return null;
    return prompt;
  }

  Future<ImpersonationOutcome> run({
    required ChatSession session,
    required String impersonationPrompt,
    String? guidanceText,
    required void Function(CancelToken) setCancelToken,
    required void Function(String text) onDelta,
  }) async {
    final cancelToken = CancelToken();
    setCancelToken(cancelToken);
    if (_isAborted() || cancelToken.isCancelled) {
      return ImpersonationOutcome.aborted;
    }

    final preset = _ref.read(
      effectivePresetForChatProvider((charId: _charId, sessionId: session.id)),
    );
    final persona = _ref.read(
      effectivePersonaForChatProvider((charId: _charId, sessionId: session.id)),
    );
    final character = await _ref.read(characterRepoProvider).getById(_charId);
    if (_isAborted()) return ImpersonationOutcome.aborted;

    // Build the instruction turn. Macros ({{char}}, {{user}}, {{guidance}}) are
    // resolved here because history messages are not macro-expanded by the
    // prompt builder. When a guidance instruction is supplied we fold in the
    // guided-impersonation wrapper (Glaze `guidedImpersonationPrompt`).
    final macroCtx = MacroContext(
      charName: character?.name ?? 'Character',
      userName: persona?.name ?? 'User',
      charId: _charId,
      sessionId: session.id,
      guidanceText: guidanceText,
    );
    var instruction = replaceMacros(impersonationPrompt, macroCtx).text.trim();
    if (guidanceText != null && guidanceText.trim().isNotEmpty) {
      final wrapper = (preset?.guidedImpersonationPrompt?.isNotEmpty == true)
          ? preset!.guidedImpersonationPrompt!
          : kDefaultGuidedImpersonationPrompt;
      final wrapped = replaceMacros(wrapper, macroCtx).text.trim();
      instruction = instruction.isEmpty ? wrapped : '$instruction\n$wrapped';
    }
    if (instruction.isEmpty) return ImpersonationOutcome.notConfigured;

    final instructionMsg = ChatMessage(
      id: generateId(),
      role: 'user',
      content: instruction,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      tokens: estimateTokens(instruction),
    );
    final promptSession = session.copyWith(
      messages: [...session.messages, instructionMsg],
    );

    // Guidance is folded into the instruction above, so the guided_generation
    // block must stay dormant here — pass guidanceText: null.
    final builder = _ref.read(promptPayloadBuilderProvider);
    final payload = await builder.buildFromSession(
      charId: _charId,
      session: promptSession,
      guidanceText: null,
      shouldAbort: _isAborted,
      cancelToken: cancelToken,
    );
    if (_isAborted()) return ImpersonationOutcome.aborted;

    final apiConfig = payload.apiConfig;
    final promptResult = await buildPromptInIsolate(payload);
    if (_isAborted()) return ImpersonationOutcome.aborted;

    const defaultTagStart = '<think>';
    const defaultTagEnd = '</think>';
    final reasoningTagStart = (preset?.reasoningStart?.isNotEmpty == true)
        ? preset!.reasoningStart!
        : (apiConfig.reasoningTagStart?.isNotEmpty == true)
        ? apiConfig.reasoningTagStart!
        : defaultTagStart;
    final reasoningTagEnd = (preset?.reasoningEnd?.isNotEmpty == true)
        ? preset!.reasoningEnd!
        : (apiConfig.reasoningTagEnd?.isNotEmpty == true)
        ? apiConfig.reasoningTagEnd!
        : defaultTagEnd;
    final hasInlineTags =
        reasoningTagStart.isNotEmpty && reasoningTagEnd.isNotEmpty;

    final apiMessages = buildApiMessages(
      promptResult.messages,
      reasoningHistoryCount: apiConfig.reasoningHistoryCount,
    );

    final accumulator = StreamAccumulator(
      tagStart: reasoningTagStart,
      tagEnd: reasoningTagEnd,
      hasInlineTags: hasInlineTags,
      headerModel: '',
      headerInline: '',
    );

    final transport = pickChatTransport(apiConfig.protocol);
    var frameScheduled = false;
    ImpersonationOutcome outcome = ImpersonationOutcome.ok;

    final idleTimeoutMs = apiConfig.firstChunkTimeoutMs > 0
        ? apiConfig.firstChunkTimeoutMs
        : 60000;
    var idleTimedOut = false;
    final idleGuard = IdleTimeoutGuard(idleTimeoutMs, () {
      idleTimedOut = true;
      cancelToken.cancel('First-chunk timeout after ${idleTimeoutMs}ms');
    });

    await transport.stream(
      request: ChatTransportRequest.fromApiConfig(
        apiConfig,
        messages: apiMessages,
        sessionId: session.id,
      ),
      cancelToken: cancelToken,
      onUpdate: (delta, reasoningDelta) {
        if (_isAborted()) return;
        if (delta.isNotEmpty || reasoningDelta?.isNotEmpty == true) {
          idleGuard.cancel();
        }
        accumulator.consumeDelta(delta, reasoningDelta: reasoningDelta);
        if (!frameScheduled) {
          frameScheduled = true;
          SchedulerBinding.instance.scheduleFrameCallback((_) {
            frameScheduled = false;
            if (_isAborted()) return;
            onDelta(accumulator.text.trimLeft());
          });
        }
      },
      onComplete: (text, reasoning, {rawResponseJson}) {
        if (_isAborted()) return;
        idleGuard.dispose();
        if (!apiConfig.stream &&
            accumulator.text.isEmpty &&
            (text.isNotEmpty || (reasoning != null && reasoning.isNotEmpty))) {
          accumulator.consumeDelta(text, reasoningDelta: reasoning);
        }
        onDelta(accumulator.text.trim());
      },
      onError: (error) {
        idleGuard.dispose();
        final isCancelled =
            (error is DioException && error.type == DioExceptionType.cancel) ||
            cancelToken.isCancelled ||
            _isAborted();
        if (isCancelled && !idleTimedOut) {
          outcome = ImpersonationOutcome.aborted;
        } else {
          outcome = ImpersonationOutcome.failed;
        }
      },
    );

    if (_isAborted()) return ImpersonationOutcome.aborted;
    return outcome;
  }
}
