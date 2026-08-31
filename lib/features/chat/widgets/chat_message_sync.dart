import 'package:collection/collection.dart';

import '../../../core/models/chat_message.dart';
import '../bridge/chat_bridge_controller.dart';

/// Pure diff between the previous and current [ChatMessage] list and
/// the dispatch of the right [ChatBridgeController] method.
///
/// Extracted from `chat_webview_widget._syncMessages` so the widget
/// can stay focused on the build / lifecycle delegation. The sync
/// contract is preserved exactly:
///   * No-op when a session switch is in progress (defer to caller).
///   * First load (old empty) → `setMessages`.
///   * Cleared (new empty) → `clearAll`.
///   * Head prepend → `prependMessages` for the prefix.
///   * Tail append → `appendMessages`.
///   * Any pure removal — head truncation, tail truncation, mid-chat
///     delete, scattered bulk delete → `removeMessage` per removed id.
///   * Shorter with a reorder → `clearAll` + `setMessages`.
///   * Same length with at least one swap → `clearAll` + `setMessages`.
///   * Same length, per-index change → `updateMessage` if the
///     content / swipe / hidden / typing / error / guidance / greeting
///     fields differ.
class ChatMessageSync {
  const ChatMessageSync();

  /// Apply the diff between [oldMsgs] and [newMsgs] using the given
  /// [bridge]. The virtual streaming placeholder is owned by the bridge and is
  /// never part of [newMsgs], so every message in this list must participate in
  /// the diff.
  /// [visibleStartIndex] is forwarded to `setMessages` / `prependMessages`
  /// for the scrollback window.
  /// [busy] suppresses `setLastMessage`, whose only job is to stamp the
  /// Regenerate button under a trailing user message. That button belongs to
  /// an idle chat: a reply already on its way is not idle. It covers the
  /// streaming window (`isGenerating`) *and* the send window before it
  /// (`ChatState.isSendPending`) — the optimistic user bubble is a tail
  /// append, so gating on `isGenerating` alone flashed a Regenerate button
  /// under the message for as long as the durable append took.
  /// [sessionSwitching] short-circuits the diff entirely so a session
  /// switch can complete its full reset.
  Future<void> sync({
    required ChatBridgeController? bridge,
    required List<ChatMessage> oldMsgs,
    required List<ChatMessage> newMsgs,
    required int visibleStartIndex,
    required bool busy,
    required bool sessionSwitching,
    void Function()? onDomReset,
  }) async {
    if (sessionSwitching) return;
    if (bridge == null) return;

    final oldIds = oldMsgs.map((m) => m.id).toList();
    final newIds = newMsgs.map((m) => m.id).toList();
    final newLen = newIds.length;

    if (oldIds.isEmpty) {
      onDomReset?.call();
      await bridge.setMessages(newMsgs, visibleStartIndex: visibleStartIndex);
      if (!busy) {
        await bridge.setLastMessage(
          lastUserMessageId(newMsgs) ?? newMsgs.lastOrNull?.id,
        );
      }
      return;
    }

    if (newIds.isEmpty) {
      onDomReset?.call();
      await bridge.clearAll();
      return;
    }

    if (newIds.length > oldIds.length) {
      final oldFirstId = oldIds.first;
      final newIdx = newIds.indexOf(oldFirstId);
      if (newIdx > 0) {
        await bridge.prependMessages(
          newMsgs.sublist(0, newIdx),
          visibleStartIndex: visibleStartIndex,
        );
        return;
      }
      if (newLen > oldIds.length) {
        final appends = newMsgs.sublist(oldIds.length, newLen);
        await bridge.appendMessages(
          appends,
          startIndex: visibleStartIndex + oldIds.length,
        );
        if (appends.isNotEmpty && !busy) {
          await bridge.setLastMessage(
            lastUserMessageId(appends) ?? newMsgs.lastOrNull?.id,
          );
        }
        return;
      }
    }

    if (newIds.length < oldIds.length) {
      // Every shrink that keeps the surviving ids in order — a head trim from
      // scrollback windowing, a tail trim from a branch/abort, a delete from
      // the middle, a bulk delete of scattered messages — is a plain list of
      // removals. Emitting them one by one keeps the WebView's exit animation
      // and its scroll position; the `clearAll` + `setMessages` fallback below
      // flashes the loading screen and re-renders the whole window instead,
      // which is what made a delete land late and with a visible stall.
      final removed = _removedIdsIfSubsequence(oldIds, newIds);
      if (removed != null) {
        for (final id in removed) {
          await bridge.removeMessage(id);
        }
        if (!busy) {
          await bridge.setLastMessage(
            lastUserMessageId(newMsgs) ?? newMsgs.lastOrNull?.id,
          );
        }
        return;
      }
      onDomReset?.call();
      await bridge.clearAll();
      await bridge.setMessages(newMsgs, visibleStartIndex: visibleStartIndex);
      if (!busy) {
        await bridge.setLastMessage(
          lastUserMessageId(newMsgs) ?? newMsgs.lastOrNull?.id,
        );
      }
      return;
    }

    final minLen = newLen < oldIds.length ? newLen : oldIds.length;
    var anyUpdated = false;
    for (int i = 0; i < minLen; i++) {
      if (i >= newIds.length) break;
      if (newIds[i] != oldIds[i]) {
        onDomReset?.call();
        await bridge.clearAll();
        await bridge.setMessages(newMsgs, visibleStartIndex: visibleStartIndex);
        if (!busy) {
          await bridge.setLastMessage(
            lastUserMessageId(newMsgs) ?? newMsgs.lastOrNull?.id,
          );
        }
        return;
      }
      final o = oldMsgs[i];
      final n = newMsgs[i];

      final contentChanged = o.content != n.content;
      final swipeChanged = o.swipeId != n.swipeId;
      final swipeTotalChanged = o.swipes.length != n.swipes.length;
      final agentSwipeChanged = o.agentSwipeId != n.agentSwipeId;
      final agentSwipeTotalChanged =
          o.agentSwipes.length != n.agentSwipes.length;
      final hiddenChanged = o.isHidden != n.isHidden;
      final imageHiddenChanged = o.imageHidden != n.imageHidden;
      final typingChanged = o.isTyping != n.isTyping;
      final errorChanged = o.isError != n.isError;
      final guidanceChanged = o.guidanceText != n.guidanceText;
      final greetingChanged = o.greetingIndex != n.greetingIndex;
      final studioOutputsChanged =
          o.studioOutputs.length != n.studioOutputs.length ||
          _studioOutputsDiffer(o.studioOutputs, n.studioOutputs);
      // Badge fields: genTime/tokens can change without any other field moving
      // (e.g. POST-cleaner finalizes a swipe that already streamed its content
      // into the bubble, so content/isTyping are unchanged but the badge must
      // update). Without these checks, updateMessage is skipped and the WebView
      // keeps the stale (or null) badge until a session re-entry forces a full
      // reload from DB.
      final genTimeChanged = o.genTime != n.genTime;
      final tokensChanged = o.tokens != n.tokens;
      // The ledger stamps the game clock onto the message after the turn,
      // post-bubble-render — the same badge-style update path as genTime.
      final timeChanged = o.time != n.time;

      final needsUpdate =
          contentChanged ||
          swipeChanged ||
          hiddenChanged ||
          imageHiddenChanged ||
          swipeTotalChanged ||
          agentSwipeChanged ||
          agentSwipeTotalChanged ||
          typingChanged ||
          errorChanged ||
          guidanceChanged ||
          greetingChanged ||
          studioOutputsChanged ||
          genTimeChanged ||
          tokensChanged ||
          timeChanged;

      if (needsUpdate) {
        await bridge.updateMessage(n);
        anyUpdated = true;
      }
    }
    // Same-length per-index edits (e.g. user editMessage while the
    // last message is still a user message) need a fresh setLastMessage
    // because the WebView footer/regen controls are not re-rendered by
    // `updateMessage`. The previous dispatcher call relied on a
    // changing isGenerating flag, which does not move on edit.
    if (anyUpdated && !busy) {
      await bridge.setLastMessage(
        lastUserMessageId(newMsgs) ?? newMsgs.lastOrNull?.id,
      );
    }
  }
}

/// Returns the ids present in [oldIds] but not in [newIds] when [newIds] is a
/// subsequence of [oldIds] — i.e. the diff is a pure removal with no reorder,
/// no insert and no id reuse. Returns null otherwise, so the caller falls back
/// to a full re-render.
///
/// Both lists are id lists in chat order. Runs a single linear walk: every
/// `newIds` entry must be matched, in order, against the remaining `oldIds`.
List<String>? _removedIdsIfSubsequence(
  List<String> oldIds,
  List<String> newIds,
) {
  final removed = <String>[];
  var newIdx = 0;
  for (final oldId in oldIds) {
    if (newIdx < newIds.length && newIds[newIdx] == oldId) {
      newIdx++;
    } else {
      removed.add(oldId);
    }
  }
  // Some new id never matched → the lists diverge by more than deletions.
  if (newIdx != newIds.length) return null;
  return removed;
}

/// Appends the virtual streaming message only after persisted message changes
/// have reached the WebView. Returns false when the generation became stale at
/// either async boundary.
Future<bool> appendStreamingPlaceholderAfterMessageSync({
  required Future<void> messageSync,
  required bool Function() isCurrent,
  required Future<void> Function() appendPlaceholder,
}) async {
  await messageSync;
  if (!isCurrent()) return false;
  await appendPlaceholder();
  return isCurrent();
}

/// Returns the id of the last message in [msgs] **only when it is a
/// user message** (otherwise `null`). The WebView needs this id to
/// inject the Regenerate button under the last user message — but the
/// button must appear *only* when that user message is genuinely the
/// last message in the chat (no char reply after it), mirroring the
/// reference UI (`ChatMessage.vue`: `role === 'user' && isLast`).
///
/// Returning a non-trailing user id here is a bug: `setLastMessage`
/// would move `data-is-last` off the trailing char message (breaking
/// swipe-to-regenerate) and show a stray Regenerate button under the
/// second-to-last user message. Callers fall back to the actual last
/// id (char) so the char section keeps its `data-is-last` flag.
String? lastUserMessageId(List<ChatMessage> msgs) {
  final last = msgs.lastOrNull;
  return last != null && last.role == 'user' ? last.id : null;
}

/// Returns `true` when both [a] and [b] contain the same object
/// references in the same order. Used by [ChatWebViewWidget] to
/// detect no-op parent rebuilds so the message sync is not even
/// invoked.
bool chatMessageListsIdentical(List<ChatMessage> a, List<ChatMessage> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}

/// Compares two studioOutputs lists by checking the `status` and `content`
/// fields of each output entry. Returns true if any entry differs.
bool _studioOutputsDiffer(
  List<Map<String, dynamic>> a,
  List<Map<String, dynamic>> b,
) {
  if (a.length != b.length) return true;
  for (var i = 0; i < a.length; i++) {
    if (a[i]['status'] != b[i]['status']) return true;
    if (a[i]['content'] != b[i]['content']) return true;
  }
  return false;
}
