import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/generation_phase.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/persona.dart';
import '../../../core/models/preset.dart';
import '../../../core/state/active_regex_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../extensions/models/info_block.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';
import '../../extensions/providers/info_blocks_provider.dart';
import '../../personas/persona_list_provider.dart';
import '../bridge/chat_bridge_controller.dart';
import '../chat_provider.dart';
import '../chat_state.dart';
import '../editing_message_provider.dart';
import '../services/continuation_message_merger.dart';
import '../state/context_window_marker.dart';
import '../state/generation_phase_provider.dart';
import 'chat_message_sync.dart';
import 'chat_streaming_bridge_sync.dart';
import 'chat_webview_sync_dispatcher.dart';

/// Wires the `build()`-side `ref.listen` plumbing for the chat
/// WebView: display regexes, editing message, streaming state,
/// ext-block DB rows, and the ext-settings / ext-presets broadcasts.
///
/// Extracted from `chat_webview_widget.dart` so the widget's build
/// method only calls [attach] once per frame. The class does not
/// own any state — it forwards the [ref.listen] callbacks to the
/// existing bridge / refresher / sync state.
class ChatWebViewBuildListeners {
  ChatWebViewBuildListeners({
    required this.ref,
    required this.bridge,
    required this.ready,
    required this.syncState,
    required this.streamingId,
    required this.charId,
    required this.sessionId,
    required this.messages,
    required this.regenTargetId,
    required this.continuationTargetId,
    required this.visibleStartIndex,
    required this.onRefreshExtBlocksPanel,
    required this.onSyncExtBlockPanels,
    required this.onReconcileActiveGeneration,
    required this.onDomReset,
    this.isCurrentBridge,
  });

  final WidgetRef ref;
  final ChatBridgeController? bridge;
  final bool Function() ready;
  final ChatWebViewSyncState syncState;
  final String streamingId;
  final String charId;
  final String? sessionId;
  final List<ChatMessage> messages;
  final String? regenTargetId;

  /// Id of the assistant message a continuation run is extending, or null.
  /// See [ChatState.continuationTargetId].
  final String? continuationTargetId;
  final int visibleStartIndex;
  final Future<void> Function(String sessionId, String messageId)
  onRefreshExtBlocksPanel;
  final Future<void> Function() onSyncExtBlockPanels;
  final Future<void> Function(ChatBridgeController bridge)
  onReconcileActiveGeneration;
  final void Function() onDomReset;
  final bool Function(ChatBridgeController bridge)? isCurrentBridge;

  /// Attach all `ref.listen` callbacks for the current build. Call
  /// from the top of `State.build` after the `ref.watch` reads.
  void attach() {
    _listenDisplayRegexes();
    _listenPersonaRoster();
    _listenEditingMessage();
    _listenGenerationPhase();
    _listenContextWindowStart();
    _listenStreaming();
    _listenInfoBlocks();
    _listenExtSettingsAndPresets();
  }

  void _listenDisplayRegexes() {
    ref.listen<AsyncValue<List<PresetRegex>>>(displayRegexesProvider, (
      prev,
      next,
    ) {
      final b = bridge;
      if (b == null || !ready()) return;
      final oldList = prev?.value ?? const <PresetRegex>[];
      final newList = next.value ?? const <PresetRegex>[];
      if (_regexListChanged(oldList, newList)) {
        final character = ref.read(characterByIdProvider(charId));
        final effectivePersona = ref.read(
          effectivePersonaForChatProvider((
            charId: charId,
            sessionId: sessionId,
          )),
        );
        b.setRegexContext(newList, character, effectivePersona);
        // Switching preset changes the active display regexes, which forces a
        // full re-render of every message. Preserve the current scroll position
        // so the chat stays put instead of jumping (see restoreAnchor in the
        // webview virtual list).
        unawaited(() async {
          onDomReset();
          await b.setMessages(
            messages,
            visibleStartIndex: visibleStartIndex,
            preserveScroll: true,
          );
          if (isCurrentBridge?.call(b) == false || !ready()) return;
          await onReconcileActiveGeneration(b);
        }());
      }
    });
  }

  /// Keeps rendered messages in step with the persona roster. A user message
  /// stores the id of the persona it was sent as, and the WebView resolves that
  /// id when it renders: renaming a persona must rename its own past messages,
  /// and deleting one must drop those messages back to a letter avatar while
  /// keeping the name stored on them. Neither reaches the page on its own —
  /// the maps are built in Dart — so the roster is re-pushed and the messages
  /// re-rendered here.
  void _listenPersonaRoster() {
    ref.listen<AsyncValue<List<Persona>>>(personaListProvider, (prev, next) {
      final b = bridge;
      if (b == null || !ready()) return;
      final oldList = prev?.value ?? const <Persona>[];
      final newList = next.value ?? const <Persona>[];
      if (!_personaRosterChanged(oldList, newList)) return;
      b.setPersonaRoster(newList);
      // Same reasoning as the display-regex re-render above: every message map
      // is affected, so the batch is a full re-render that keeps the scroll
      // position.
      unawaited(() async {
        onDomReset();
        await b.setMessages(
          messages,
          visibleStartIndex: visibleStartIndex,
          preserveScroll: true,
        );
        if (isCurrentBridge?.call(b) == false || !ready()) return;
        await onReconcileActiveGeneration(b);
      }());
    });
  }

  void _listenEditingMessage() {
    ref.listen<String?>(editingMessageIdProvider(charId), (prev, next) {
      final b = bridge;
      if (b == null || !ready()) return;
      if (prev != null && prev != next) {
        // Await stopEdit before re-injecting Regenerate. The old path
        // also called updateMessage() without awaiting stopEdit; that
        // raced in the JS update batcher, cleared footer controls while
        // `editing` was still set, and left the last-user Regenerate
        // missing on save/cancel. Message content sync runs separately
        // when editMessage updates the provider.
        //
        // Always call setLastMessage after stopEdit regardless of which
        // message was edited — stopEdit restores the original footer HTML,
        // which clears the Regenerate button injected by setLastMessage.
        // Without this, swiping to regenerate stops working after any edit.
        unawaited(() async {
          await b.stopEdit(prev);
          // Fall back to the actual last message id (a trailing char)
          // so its `data-is-last` flag is re-stamped and swipe-to-
          // regenerate keeps working — `lastUserMessageId` only returns
          // a non-null id when a user message is genuinely last.
          final lastId = lastUserMessageId(messages) ?? messages.lastOrNull?.id;
          final state = ref.read(chatProvider(charId)).value;
          final isBusy =
              state?.isGenerating == true ||
              state?.isGeneratingImage == true ||
              state?.isPostGenRunning == true;
          if (lastId != null && !isBusy) {
            await b.setLastMessage(lastId);
          }
        }());
      }
      if (next != null) {
        b.startEdit(next);
      }
    });
  }

  /// Pushes the live generation phase into the typing bubble, so its label
  /// tracks the work the app is actually doing (assembling the prompt,
  /// retrieving memory, waiting on the model) instead of claiming the reply
  /// is being written from the moment the bubble appears.
  /// Keeps the CONTEXT LIMIT rule on the message the prompt actually starts
  /// at. The boundary moves whenever a prompt is built — a turn, the inspector
  /// preview, the drawer's recount — and is cleared with the breakdown itself
  /// (a delete, a changed connection): pushing the null through is what retires
  /// a rule the trim no longer draws.
  void _listenContextWindowStart() {
    ref.listen<String?>(contextWindowStartProvider(charId), (prev, next) {
      final b = bridge;
      if (b == null || !ready()) return;
      if (prev == next) return;
      unawaited(b.setContextWindowStart(next));
    });
  }

  void _listenGenerationPhase() {
    ref.listen<GenerationPhase>(generationPhaseProvider(charId), (prev, next) {
      final b = bridge;
      if (b == null || !ready() || isCurrentBridge?.call(b) == false) return;
      final label = generationPhaseLabel(next);
      if (label == b.generationPhaseLabel) return;
      unawaited(b.setGenerationPhase(label));
    });
  }

  void _listenStreaming() {
    final listenerEpoch = syncState.streamEpoch;
    ref.listen<StreamingState>(streamingStateProvider(charId), (prev, next) {
      final b = bridge;
      if (b == null ||
          !ready() ||
          syncState.streamEpoch != listenerEpoch ||
          isCurrentBridge?.call(b) == false) {
        return;
      }
      if (next.text.isEmpty && next.reasoning == null) {
        return;
      }

      final regenId = regenTargetId;
      if (regenId != null) {
        final idx = messages.indexWhere((m) => m.id == regenId);
        if (idx >= 0) {
          final original = messages[idx];
          final updated = original.copyWith(
            content: next.text,
            reasoning: next.reasoning ?? original.reasoning,
            isTyping: true,
          );
          b.updateMessage(updated);
          syncState.regenStreamingSent = true;
        }
        return;
      }

      // Continuation streaming: the reply extends an existing assistant
      // message, so grow that bubble in place. Appending a virtual streaming
      // message instead would show the continuation as its own block that
      // visibly collapses into the original once the merged message lands.
      final continuationId = continuationTargetId;
      if (continuationId != null) {
        final idx = messages.indexWhere((m) => m.id == continuationId);
        if (idx >= 0) {
          final original = messages[idx];
          final updated = original.copyWith(
            content: joinContinuation(original.content, next.text),
            // Stream the reasoning exactly the way the merge will persist it:
            // the continuation's thinking is filed under its own `Continue`
            // header rather than replacing the original turn's (INV-CM5).
            reasoning:
                joinContinuationReasoning(original.reasoning, next.reasoning) ??
                original.reasoning,
            isTyping: true,
          );
          b.updateMessage(updated);
          // No virtual streaming message was appended for this run, so the
          // falling edge must not try to remove one.
          syncState.regenStreamingSent = true;
          return;
        }
      }

      // POST-cleaner streaming: rewrite the existing last assistant message
      // in place. targetMessageId points at the message being cleaned; the
      // cleaner streams its rewrite into the same bubble, replacing the
      // original text. After the cleaner finalizes, applyCleanedText appends
      // a new green swipe with the cleaned content.
      final targetId = next.targetMessageId;
      if (targetId != null) {
        final idx = messages.indexWhere((m) => m.id == targetId);
        if (idx >= 0) {
          final original = messages[idx];
          final updated = original.copyWith(content: next.text, isTyping: true);
          b.updateMessage(updated);
        }
        return;
      }

      final msg = ChatMessage(
        id: streamingId,
        role: 'assistant',
        content: next.text,
        reasoning: next.reasoning,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isTyping: true,
      );

      unawaited(_pushStreamingMessage(b, msg, listenerEpoch));
    });
  }

  Future<void> _pushStreamingMessage(
    ChatBridgeController bridge,
    ChatMessage message,
    int epoch,
  ) => pushStreamingMessageOwned(
    bridge: bridge,
    message: message,
    syncState: syncState,
    epoch: epoch,
    isCurrent: () => ready() && (isCurrentBridge?.call(bridge) ?? true),
  );

  void _listenInfoBlocks() {
    final sid = sessionId;
    if (sid == null || sid.isEmpty) return;
    ref.listen<List<InfoBlock>>(infoBlocksProvider(sid), (prev, next) {
      if (bridge == null || !ready()) return;
      // Only assistant/character messages can show ext-block panels.
      // Build a set of their IDs so block messageIds from afterUser
      // (which are stored under the user message id) are filtered out.
      final assistantIds = {
        for (final m in messages)
          if (m.role == 'assistant' || m.role == 'character') m.id,
      };
      final blockIds = <String>{
        for (final b in prev ?? const <InfoBlock>[]) b.messageId,
        for (final b in next) b.messageId,
      };
      final allIds = assistantIds.union(blockIds.intersection(assistantIds));
      for (final msgId in allIds) {
        unawaited(onRefreshExtBlocksPanel(sid, msgId));
      }
    });
  }

  void _listenExtSettingsAndPresets() {
    ref.listen(extensionsSettingsProvider, (_, _) {
      if (bridge != null && ready()) {
        unawaited(onSyncExtBlockPanels());
      }
    });
    ref.listen(extensionPresetsProvider, (_, _) {
      if (bridge != null && ready()) {
        unawaited(onSyncExtBlockPanels());
      }
    });
  }

  /// True when the roster changed in a way a rendered message can show: which
  /// personas exist, their names, or their avatars. Anything else about a
  /// persona (its prompt, say) never reaches the chat bubble.
  static bool _personaRosterChanged(List<Persona> a, List<Persona> b) {
    if (a.length != b.length) return true;
    final byId = {for (final p in a) p.id: p};
    for (final p in b) {
      final old = byId[p.id];
      if (old == null || old.name != p.name || old.avatarPath != p.avatarPath) {
        return true;
      }
    }
    return false;
  }

  static bool _regexListChanged(List<PresetRegex> a, List<PresetRegex> b) {
    if (a.length != b.length) return true;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].disabled != b[i].disabled) return true;
    }
    return false;
  }
}
