import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/chat_message.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/utils/time_helpers.dart';
import '../../../chat_history/chat_history_provider.dart';
import '../../chat_session_service.dart';
import '../../chat_state.dart';
import '../generation_pipeline.dart' show GenerationOutcome;
import '../variation_error_state.dart';
import 'stage_context.dart';

/// Resolves the regen result: success / rollback / no-restoration branches.
/// Extracted from [GenerationPipeline._resolveRegenResult].
class RegenResolver {
  final StageContext ctx;

  RegenResolver(this.ctx);

  /// Returns the final state to apply if [regenTargetId] was set, or null
  /// to fall through to the normal-result path.
  Future<GenerationOutcome?> resolve({
    required ChatState result,
    required String? regenTargetId,
    required ChatSession? saveSession,
    required ChatSession session,
    required int genId,
  }) async {
    if (regenTargetId == null) return null;

    if (result.regenTargetId == regenTargetId) {
      ctx.setState(
        AsyncData(result.copyWith(isGenerating: false, regenTargetId: null)),
      );
      ctx.abortHandler.restorationMessage = null;
      return GenerationOutcome(
        state: ctx.getState().value ?? result,
        clearRestorationMessage: null,
      );
    }

    final original = ctx.abortHandler.restorationMessage;
    if (original == null) {
      ctx.setState(
        AsyncData(result.copyWith(isGenerating: false, regenTargetId: null)),
      );
      return GenerationOutcome(
        state: ctx.getState().value ?? result,
        clearRestorationMessage: null,
      );
    }

    final restoreSession = saveSession ?? session;
    final idx = restoreSession.messages.indexWhere(
      (m) => m.id == regenTargetId,
    );
    if (idx < 0) {
      ctx.setState(
        AsyncData(result.copyWith(isGenerating: false, regenTargetId: null)),
      );
      ctx.abortHandler.restorationMessage = null;
      return GenerationOutcome(
        state: ctx.getState().value ?? result,
        clearRestorationMessage: null,
      );
    }

    final rollbackSwipes = original.swipes.isNotEmpty
        ? original.swipes
        : [original.content];
    final rollbackSwipesMeta = original.swipesMeta.isNotEmpty
        ? original.swipesMeta
        : [
            <String, dynamic>{
              'genTime': original.genTime,
              'reasoning': original.reasoning,
              'tokens': original.tokens,
            },
          ];
    final restored = restoreSession.messages[idx].copyWith(
      content: original.content,
      swipeId: original.swipeId,
      swipes: rollbackSwipes,
      reasoning: original.reasoning,
      genTime: original.genTime,
      tokens: original.tokens,
      swipesMeta: rollbackSwipesMeta,
      swipeDirection: original.swipeDirection,
      isTyping: false,
      // Rolling back restores the pre-regen variation verbatim — including its
      // error state. Clearing it here turned an errored variation into a
      // normal-looking bubble whose text is an error message.
      isError: restoredVariationIsError(original, rollbackSwipesMeta),
    );
    final expected = result.session?.messages
        .where((message) => message.id == regenTargetId)
        .firstOrNull;
    ChatSession? durableSession;
    try {
      if (expected != null) {
        durableSession = await ctx.ref
            .read(chatRepoProvider)
            .mutateSession(
              sessionId: restoreSession.id,
              updatedAt: currentTimestampSeconds(),
              mutate: (latest) {
                if (!ctx.abortHandler.isCurrentGen(genId)) return null;
                final latestIdx = latest.messages.indexWhere(
                  (message) => message.id == regenTargetId,
                );
                if (latestIdx < 0 ||
                    !_sameGenerationAnchor(
                      expected,
                      latest.messages[latestIdx],
                    )) {
                  return null;
                }
                final messages = [...latest.messages];
                messages[latestIdx] = restored.copyWith(
                  isHidden: messages[latestIdx].isHidden,
                  imageHidden: messages[latestIdx].imageHidden,
                );
                return latest.copyWith(messages: messages);
              },
            );
      }
      durableSession ??= await ctx.ref
          .read(chatRepoProvider)
          .getById(restoreSession.id);
    } catch (e) {
      debugPrint('[RegenResolver] failed to persist restored session: $e');
      try {
        durableSession = await ctx.ref
            .read(chatRepoProvider)
            .getById(restoreSession.id);
      } catch (reloadError) {
        debugPrint(
          '[RegenResolver] failed to reload current session: $reloadError',
        );
      }
    }
    if (!ctx.ref.mounted || !ctx.abortHandler.isCurrentGen(genId)) return null;
    if (durableSession == null) {
      return GenerationOutcome(
        state: ctx.getState().value ?? result,
        clearRestorationMessage: original,
      );
    }
    ChatSessionService.updateCache(durableSession);
    ctx.ref.invalidate(chatHistoryProvider);
    ctx.abortHandler.restorationMessage = null;
    ctx.setState(
      AsyncData(
        ChatState(
          session: durableSession,
          isGenerating: false,
          error: result.error,
          regenTargetId: null,
        ),
      ),
    );
    return GenerationOutcome(
      state: ctx.getState().value ?? result,
      clearRestorationMessage: null,
    );
  }

  static bool _sameGenerationAnchor(ChatMessage expected, ChatMessage current) {
    return expected.content == current.content &&
        expected.swipeId == current.swipeId &&
        expected.agentSwipeId == current.agentSwipeId &&
        jsonEncode(expected.swipes) == jsonEncode(current.swipes) &&
        jsonEncode(expected.swipesMeta) == jsonEncode(current.swipesMeta) &&
        jsonEncode(
              expected.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            ) ==
            jsonEncode(
              current.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            );
  }
}
