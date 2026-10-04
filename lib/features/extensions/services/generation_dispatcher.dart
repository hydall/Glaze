import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/game_time.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/studio_turn_config_resolver.dart';
import '../../../core/utils/error_format.dart';
import '../../chat/chat_provider.dart';
import '../../chat/chat_state.dart';
import '../../chat/editing_message_provider.dart';
import '../models/trigger_mode.dart';
import '../models/trigger_result.dart';

/// Dispatcher that the JS extension bridge uses to start / continue /
/// regenerate a chat generation. The dispatcher is the only place where
/// extension code talks to [ChatNotifier] — it enforces all of the chat
/// generation invariants that the regular UI flow enforces:
///
/// - INV-C1: at most one active generation per `charId`. The call is
///   rejected (not auto-aborted) when `isGenerating == true` so the JS
///   script can decide whether to retry / await.
/// - INV-CM1 / INV-CM2 / INV-A3: `continue` and `regenerate` delegate to
///   the regular [ChatNotifier.continueMessage] /
///   [ChatNotifier.regenerateLastAssistant] entry points so the same
///   abort / `genId` / partial-text semantics apply.
///
/// The dispatcher never throws — it always returns a typed
/// [TriggerResult] so the JS SDK can surface a structured error.
class GenerationDispatcher {
  GenerationDispatcher(this._ref);

  final Ref? _ref;

  /// Resolve [rawMode] (a JS-supplied string) and dispatch the generation
  /// against the chat notifier of [charId].
  Future<TriggerResult> dispatch({
    required String charId,
    String? rawMode,
    String? reason,
  }) async {
    final mode = TriggerMode.parse(rawMode);
    if (kDebugMode) {
      debugPrint(
        '[GenerationDispatcher] dispatch charId=$charId mode=$mode reason=$reason',
      );
    }

    final ref = _ref!;
    final ChatNotifier? notifier = ref.read(chatProvider(charId).notifier);

    if (notifier == null) {
      return TriggerNoSession(mode: mode);
    }

    final current = ref.read(chatProvider(charId)).value;
    if (current == null || current.session == null) {
      return TriggerNoSession(mode: mode);
    }

    if (ref.read(editingMessageIdProvider(charId)) != null) {
      return TriggerBusy(busyKind: 'message_edit', mode: mode);
    }

    if (current.isGenerating || current.isPostGenRunning) {
      return TriggerBusy(busyKind: 'chat', mode: mode);
    }

    final resolved = _resolveAuto(current, mode);

    try {
      final checkedSessionId = current.session!.id;
      if (!current.session!.messages.any((message) => message.role == 'user')) {
        final turnConfig = await ref
            .read(studioTurnConfigResolverProvider)
            .resolve(checkedSessionId);
        if (turnConfig.enabled && turnConfig.ledgerEnabled) {
          final trackerRepo = ref.read(trackerRepoProvider);
          final trackers = await Future.wait([
            trackerRepo.get(checkedSessionId, GameTimeState.timeKey),
            trackerRepo.get(checkedSessionId, GameTimeState.dateKey),
            trackerRepo.get(checkedSessionId, GameTimeState.dayKey),
          ]);
          if (GameTimeState.fromTrackers(trackers.nonNulls).format() == null) {
            return TriggerError(
              message:
                  'Studio Ledger requires a complete game date and time before generation.',
              mode: resolved,
            );
          }
        }
      }

      final latest = ref.read(chatProvider(charId)).value;
      if (latest?.session?.id != checkedSessionId) {
        return TriggerNoSession(mode: resolved);
      }
      if (latest!.isGenerating || latest.isPostGenRunning) {
        return TriggerBusy(busyKind: 'chat', mode: resolved);
      }

      switch (resolved) {
        case TriggerMode.continueGeneration:
          await notifier.continueMessage();
        case TriggerMode.regenerate:
          await notifier.regenerateLastAssistant();
        case TriggerMode.auto:
          break;
      }
    } catch (e) {
      return TriggerError(message: formatError(e), mode: resolved);
    }

    return TriggerAccepted(mode: resolved, reason: reason);
  }

  /// Read-only variant used by the handler for `validate` paths.
  /// Returns the resolved mode (or null when the chat is busy / no session
  /// is available) without actually starting a generation.
  TriggerMode? peekResolvedMode({required String charId, String? rawMode}) {
    final ref = _ref!;
    final current = ref.read(chatProvider(charId)).value;
    if (current == null || current.session == null) return null;
    if (ref.read(editingMessageIdProvider(charId)) != null) return null;
    if (current.isGenerating || current.isPostGenRunning) return null;
    return _resolveAuto(current, TriggerMode.parse(rawMode));
  }

  TriggerMode _resolveAuto(ChatState current, TriggerMode requested) {
    if (requested != TriggerMode.auto) return requested;
    final msgs = current.messages;
    if (msgs.isEmpty) return TriggerMode.regenerate;
    final last = msgs.last;
    if (last.role == 'assistant') return TriggerMode.continueGeneration;
    return TriggerMode.regenerate;
  }
}

/// Riverpod entry point. Resolved with `ref.read` (not `watch`) — the
/// dispatcher is stateless and has no reactive state of its own.
final generationDispatcherProvider = Provider<GenerationDispatcher>((ref) {
  return GenerationDispatcher(ref);
});
