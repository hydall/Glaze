import 'dart:async';

import 'package:collection/collection.dart';

import '../../../core/models/chat_message.dart';
import '../bridge/chat_bridge_controller.dart';
import '../bridge/chat_overlay_blur_region.dart';
import 'chat_message_sync.dart'
    show chatMessageListsIdentical, lastUserMessageId;

/// Mutable per-frame state owned by the [ChatWebViewSyncDispatcher].
/// Lifted out of the widget so the dispatcher can be tested in
/// isolation. These fields are written from `didUpdateWidget`
/// and read by other lifecycle hooks (e.g. the streaming
/// `ref.listen` in `build`).
class ChatWebViewSyncState {
  bool wasGenerating = false;
  bool streamingSent = false;
  bool regenStreamingSent = false;

  /// Tail of the ordered message-list mutation queue. Persisted diffs,
  /// placeholders, and streaming deltas must share one queue because mapping a
  /// message can await image resolution before it reaches JavaScript.
  Future<void>? messageMutationPending;

  Future<void> enqueueMessageMutation(Future<void> Function() mutation) {
    final previous = messageMutationPending;
    late final Future<void> operation;
    operation = () async {
      try {
        if (previous != null) {
          try {
            await previous;
          } catch (_) {
            // A failed bridge call must not permanently poison the queue.
          }
        }
        await mutation();
      } finally {
        if (identical(messageMutationPending, operation)) {
          messageMutationPending = null;
        }
      }
    }();
    messageMutationPending = operation;
    return operation;
  }

  /// Invalidates async streaming work when generation or session ownership
  /// changes. Callers capture the value and re-check it after every await.
  int streamEpoch = 0;
}

/// Per-field diff dispatch for [ChatWebViewWidget.didUpdateWidget].
///
/// Extracted from the widget because the original method had grown
/// past 180 lines with 14 hand-written diff branches. The dispatcher
/// is a plain class (no mixin) that holds a reference to the
/// [ChatBridgeController] and the parent widget's [old] + [current]
/// state, plus a small [ChatWebViewSyncState] bundle for the streaming
/// placeholders. Public methods are scoped to one concern each so
/// future changes (e.g. another field) add a new branch without
/// touching the others.
class ChatWebViewSyncDispatcher {
  ChatWebViewSyncDispatcher({required this.state}) : assert(true);

  final ChatWebViewSyncState state;

  /// Apply the diff between the previous and current [ChatWebViewWidget].
  ///
  /// Returns a [ChatWebViewSyncResult] that tells the caller whether
  /// the message sync and ext-block sync should run (`runMessageSync`)
  /// and whether a streaming placeholder should be appended to the
  /// bridge (`appendPlaceholder` + `placeholderMessage`). When
  /// `sessionSwitched` is `true` the caller should *not* call
  /// [ChatMessageSync.sync] — the session switch path handles that
  /// itself with a full bridge reset.
  ChatWebViewSyncResult dispatch({
    required ChatBridgeController? bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
    required List<ChatMessage> oldMessages,
    required List<ChatMessage> newMessages,
    required String streamingId,
    required Future<void> Function() onSyncExtBlockPanels,
    required Future<void> Function(ChatMessage) appendMessage,
    required ChatMessage Function() buildStreamingPlaceholder,
    bool ready = true,
    bool isImpersonating = false,
  }) {
    if (!ready || bridge == null) {
      // Still need to keep `wasGenerating` rolling for the next frame
      // so the placeholder injection can detect the rising edge.
      state.wasGenerating = current.isGenerating;
      return const ChatWebViewSyncResult(
        runMessageSync: false,
        appendPlaceholder: false,
        sessionSwitched: false,
      );
    }

    _maybeUpdateMemoryBook(bridge: bridge, old: old, current: current);

    if (current.charId != old.charId || current.sessionId != old.sessionId) {
      // The actual session switch is performed by the caller; we just
      // record the rising edge of `wasGenerating` so the post-switch
      // `didUpdateWidget` doesn't re-inject the placeholder.
      state.wasGenerating = current.isGenerating;
      state.streamEpoch++;
      return const ChatWebViewSyncResult(
        runMessageSync: false,
        appendPlaceholder: false,
        sessionSwitched: true,
      );
    }

    if (_identityChanged(old: old, current: current)) {
      bridge.setIdentity(
        charName: current.charName,
        charColor: current.charColor,
        personaName: current.personaName,
        layout: current.chatLayout,
        charAvatarPath: current.charAvatarPath,
        personaAvatarPath: current.personaAvatarPath,
        greetingTotal: current.greetingTotal,
      );
    }

    _maybeApplyTheme(bridge: bridge, old: old, current: current);
    _maybeApplyBackgroundImage(bridge: bridge, old: old, current: current);
    _maybeApplyBackgroundNoise(bridge: bridge, old: old, current: current);
    _maybeApplyChatFont(bridge: bridge, old: old, current: current);
    _maybeApplySelectionMode(bridge: bridge, old: old, current: current);
    _maybeApplyMessageSettings(bridge: bridge, old: old, current: current);
    final rehighlightSearch = _maybeApplySearch(
      bridge: bridge,
      old: old,
      current: current,
    );
    _maybeApplyInsets(bridge: bridge, old: old, current: current);

    _maybeApplyGeneratingState(bridge: bridge, old: old, current: current);

    // Level-reconcile the native-side streaming flags too. If the previous
    // generation's falling edge was missed while the WebView was not ready or
    // during a session switch, `streamingSent` can stay true. The next user
    // send then looks like "messages + generating" and ChatMessageSync would
    // incorrectly skip the just-appended persisted user message as if it were
    // the virtual streaming placeholder.
    if (!state.wasGenerating && current.isGenerating) {
      state.streamEpoch++;
      state.streamingSent = false;
      state.regenStreamingSent = false;
    }

    if (state.wasGenerating && !current.isGenerating) {
      state.streamEpoch++;
      if (!state.regenStreamingSent) {
        bridge.removeMessage(streamingId);
      }
      state.streamingSent = false;
      state.regenStreamingSent = false;
      unawaited(onSyncExtBlockPanels());
    } else if (!current.isGenerating) {
      state.streamingSent = false;
      state.regenStreamingSent = false;
    }

    final runMessageSync =
        !identical(oldMessages, newMessages) &&
        !chatMessageListsIdentical(oldMessages, newMessages);

    // Continuation started → the reply extends an existing bubble, so flag
    // that one as typing instead of appending a placeholder. The streaming
    // listener then grows it in place (see ChatWebViewBuildListeners).
    final continuationId = current.continuationTargetId;
    if (!state.wasGenerating &&
        current.isGenerating &&
        continuationId != null) {
      final target = current.messages.firstWhereOrNull(
        (m) => m.id == continuationId,
      );
      if (target != null) {
        bridge.updateMessage(target.copyWith(isTyping: true));
        state.regenStreamingSent = true;
      }
    }

    // Fresh generation started (no regen/continuation target) → inject typing
    // placeholder. Impersonation reuses the generating flag but streams into
    // the composer, not the chat, so it must never spawn a typing bubble.
    final shouldInjectPlaceholder =
        !state.wasGenerating &&
        current.isGenerating &&
        current.regenTargetId == null &&
        continuationId == null &&
        !state.streamingSent &&
        !isImpersonating;
    state.wasGenerating = current.isGenerating;

    return ChatWebViewSyncResult(
      runMessageSync: runMessageSync,
      appendPlaceholder: shouldInjectPlaceholder,
      sessionSwitched: false,
      placeholder: shouldInjectPlaceholder ? buildStreamingPlaceholder() : null,
      rehighlightSearch: rehighlightSearch,
    );
  }

  /// Append the streaming placeholder to the bridge and flip
  /// [ChatWebViewSyncState.streamingSent] to `true`. Called by the
  /// widget after [dispatch] returns `appendPlaceholder: true`.
  void onPlaceholderAppended() {
    state.streamingSent = true;
  }

  void _maybeUpdateMemoryBook({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.memoryEntries != old.memoryEntries ||
        current.memoryDrafts != old.memoryDrafts) {
      unawaited(
        bridge.updateMemoryBookData(
          entries: current.memoryEntries
              .map((e) => {'status': e.status, 'messageIds': e.messageIds})
              .toList(),
          pendingDrafts: current.memoryDrafts
              .map((e) => {'messageIds': e.messageIds})
              .toList(),
        ),
      );
    }
  }

  void _maybeApplyTheme({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.themeSyncKey != old.themeSyncKey ||
        current.chatLayout != old.chatLayout ||
        current.elementOpacity != old.elementOpacity ||
        current.elementBlur != old.elementBlur ||
        current.chatFontSize != old.chatFontSize) {
      bridge.applyTheme(current.buildThemeMap());
    }
  }

  void _maybeApplyBackgroundImage({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.bgImagePath != old.bgImagePath ||
        current.bgBlur != old.bgBlur ||
        current.bgDim != old.bgDim) {
      bridge.setBackgroundImage(current.bgImagePath, current.bgBlur.toInt());
      bridge.applyTheme({'bg-dim': current.bgDim.toStringAsFixed(2)});
    }
  }

  void _maybeApplyBackgroundNoise({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.bgNoiseOpacity != old.bgNoiseOpacity ||
        current.bgNoiseIntensity != old.bgNoiseIntensity) {
      bridge.setBackgroundNoise(
        current.bgNoiseOpacity,
        current.bgNoiseIntensity,
      );
    }
  }

  void _maybeApplyChatFont({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.chatFontName != old.chatFontName ||
        current.chatFontDataUrl != old.chatFontDataUrl ||
        current.chatFontSize != old.chatFontSize ||
        current.chatLetterSpacing != old.chatLetterSpacing) {
      bridge.setChatFont(
        fontName: current.chatFontName,
        fontDataUrl: current.chatFontDataUrl,
        fontSize: current.chatFontSize,
        letterSpacing: current.chatLetterSpacing,
      );
    }
  }

  void _maybeApplySelectionMode({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.isSelectionMode != old.isSelectionMode) {
      bridge.setSelectionMode(current.isSelectionMode);
    }
  }

  void _maybeApplyMessageSettings({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.batterySaver != old.batterySaver ||
        current.hideMessageId != old.hideMessageId ||
        current.hideGenerationTime != old.hideGenerationTime ||
        current.hideTokenCount != old.hideTokenCount ||
        current.disableSwipeRegeneration != old.disableSwipeRegeneration ||
        current.studioEnabled != old.studioEnabled) {
      bridge.setMessageSettings(
        batterySaver: current.batterySaver,
        hideMessageId: current.hideMessageId,
        hideGenerationTime: current.hideGenerationTime,
        hideTokenCount: current.hideTokenCount,
        disableSwipeRegeneration: current.disableSwipeRegeneration,
        studioEnabled: current.studioEnabled,
      );
    }
  }

  /// Returns `true` when the highlight pass must run *after* the message sync
  /// instead of now.
  ///
  /// A revision bump means the messages themselves changed under an open
  /// search (an edit, a delete, a swipe). Highlighting reads the bubbles that
  /// are currently in the DOM, and the message sync that carries the new text
  /// is queued after this dispatch — re-highlighting here would number the
  /// matches over the *old* text and then have the edited bubble rewritten on
  /// top, which is exactly the stale highlight this defers around.
  bool _maybeApplySearch({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    if (current.searchRevision != old.searchRevision) return true;
    if (current.searchQuery == old.searchQuery &&
        current.searchCurrentIndex == old.searchCurrentIndex) {
      return false;
    }
    applySearch(bridge: bridge, fields: current);
    return false;
  }

  /// Pushes the current query + active index into the page. Public so the
  /// widget can re-run it once the deferred message sync has landed.
  ///
  /// [scroll] is `false` for that deferred re-run: it only re-numbers the
  /// highlights over the new text, and scrolling to the active match would
  /// yank the reader away from the message they just edited.
  void applySearch({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields fields,
    bool scroll = true,
  }) {
    final query = fields.searchQuery;
    if (query != null && query.isNotEmpty) {
      bridge.setSearch(
        query: query,
        activeIndex: fields.searchCurrentIndex,
        scroll: scroll,
      );
    } else {
      bridge.setSearch(query: '', activeIndex: -1);
    }
  }

  void _maybeApplyInsets({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    // The viewport height is part of the same push: the page subtracts the
    // viewport shrink it measures against it, so a stale height would mis-split
    // the inset (see LayoutBridgeCommands.setBottomPadding).
    if (current.bottomInset != old.bottomInset ||
        current.viewportHeight != old.viewportHeight) {
      bridge.setBottomPadding(
        current.bottomInset,
        viewportHeight: current.viewportHeight,
      );
    }
    if (current.topInset != old.topInset) {
      bridge.setTopPadding(current.topInset);
    }
    if (!const ListEquality<ChatOverlayBlurRegion>().equals(
      current.blurRegions,
      old.blurRegions,
    )) {
      bridge.setOverlayBlurRegions(current.blurRegions);
    }
  }

  /// Reconcile the WebView's stream and post-generation state
  /// **level-triggered**, not edge-triggered. The two flags deliberately stay
  /// separate: message controls use the stream flag to distinguish a live
  /// reply from post-generation work, while JS combines them internally for
  /// activity-only UI such as the generation timer and scroll header.
  ///
  /// Comparing against the bridge's last received values (rather than only the
  /// previous widget) catches an edge that was missed while the bridge was not
  /// ready or during a session switch. A lost falling edge would otherwise
  /// leave JS activity stuck on; a lost rising edge can render an actionable
  /// Regenerate control while a response is running.
  void _maybeApplyGeneratingState({
    required ChatBridgeController bridge,
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    final streamChanged = current.isGenerating != bridge.isGenerating;
    final postGenChanged = current.isPostGenRunning != bridge.isPostGenRunning;
    final imageChanged = current.isGeneratingImage != bridge.isGeneratingImage;
    if (!streamChanged && !postGenChanged && !imageChanged) {
      return;
    }

    bridge.isGenerating = current.isGenerating;
    bridge.isPostGenRunning = current.isPostGenRunning;
    bridge.isGeneratingImage = current.isGeneratingImage;
    bridge.evalJs(
      'if (window.bridge) { '
      'window.bridge.setGenerating(${current.isGenerating}); '
      'window.bridge.setPostGenRunning(${current.isPostGenRunning}); '
      'window.bridge.isGeneratingImage = ${current.isGeneratingImage}; '
      '}',
    );

    if (!current.isGenerating &&
        !current.isGeneratingImage &&
        current.messages.isNotEmpty) {
      bridge.setLastMessage(
        lastUserMessageId(current.messages) ?? current.messages.last.id,
      );
    } else if (current.isGenerating) {
      bridge.setLastMessage(null);
    }

    // Stream/post-gen state changes do not necessarily alter the message list,
    // so ChatMessageSync will not update its final assistant bubble. Explicitly
    // refresh it with the new, separate flags so its Stop/Guided/Regenerate
    // controls always reconcile at the stream → post-gen → settled boundaries.
    if ((old.isGenerating != current.isGenerating ||
            old.isPostGenRunning != current.isPostGenRunning) &&
        current.messages.isNotEmpty) {
      final lastAssistant = current.messages.lastWhereOrNull(
        (message) => message.role == 'assistant' || message.role == 'character',
      );
      if (lastAssistant != null) {
        // Only stamp `data-is-last` on this assistant bubble when it is
        // genuinely the trailing message. After a cancelled generation the
        // trailing message is often a *user* message (the empty assistant
        // placeholder was trimmed), so `lastAssistant` is an earlier char
        // bubble that is NOT last. Marking it isLast=true then leaves two
        // `data-is-last` sections in the DOM: the user message (flagged by the
        // `setLastMessage` call above, which also injects its Regenerate
        // button) and this stray char bubble. `setLastMessage` only clears a
        // single match, so on the next generation the stray flag survives and
        // the user-message Regenerate button can never be hidden. Passing the
        // real trailing state keeps exactly one `data-is-last` in the DOM.
        final assistantIsTrailing =
            current.messages.last.id == lastAssistant.id;
        bridge.updateMessage(
          lastAssistant,
          isLast: assistantIsTrailing && !current.isGenerating,
        );
      }
    }
  }

  static bool _identityChanged({
    required ChatWebViewWidgetFields old,
    required ChatWebViewWidgetFields current,
  }) {
    return old.charName != current.charName ||
        old.charColor != current.charColor ||
        old.personaName != current.personaName ||
        old.charAvatarPath != current.charAvatarPath ||
        old.personaAvatarPath != current.personaAvatarPath ||
        old.chatLayout != current.chatLayout ||
        old.greetingTotal != current.greetingTotal;
  }
}

/// Result of a [ChatWebViewSyncDispatcher.dispatch] call.
class ChatWebViewSyncResult {
  const ChatWebViewSyncResult({
    required this.runMessageSync,
    required this.appendPlaceholder,
    required this.sessionSwitched,
    this.placeholder,
    this.rehighlightSearch = false,
  });

  /// `true` when the caller should call
  /// [ChatMessageSync.sync] for the message list.
  final bool runMessageSync;

  /// `true` when the dispatcher wants the caller to append a
  /// streaming placeholder to the bridge. [placeholder] is the
  /// message to append (built by the widget because it needs the
  /// current timestamp + role).
  final bool appendPlaceholder;

  /// `true` when a session switch was detected. The caller handles
  /// the actual switch.
  final bool sessionSwitched;

  /// Placeholder to append when [appendPlaceholder] is `true`.
  final ChatMessage? placeholder;

  /// `true` when the search highlights must be re-applied once the queued
  /// message mutations have landed — the message list changed under an open
  /// search, so the page is showing highlights numbered over the old text.
  final bool rehighlightSearch;
}

/// Pure data snapshot of all the [ChatWebViewWidget] fields that the
/// dispatcher compares. The widget builds a snapshot for both [old]
/// and [current] on every `didUpdateWidget` so the dispatcher doesn't
/// have to reach into `widget` directly.
class ChatWebViewWidgetFields {
  const ChatWebViewWidgetFields({
    required this.charId,
    required this.charName,
    required this.charColor,
    required this.personaName,
    required this.charAvatarPath,
    required this.personaAvatarPath,
    required this.bgImagePath,
    required this.bgBlur,
    required this.bgDim,
    required this.bgNoiseOpacity,
    required this.bgNoiseIntensity,
    required this.bottomInset,
    this.viewportHeight = 0,
    required this.topInset,
    this.blurRegions = const [],
    required this.searchQuery,
    required this.searchCurrentIndex,
    this.searchRevision = 0,
    required this.chatLayout,
    required this.themeSyncKey,
    required this.elementOpacity,
    required this.elementBlur,
    required this.uiFontWeight,
    required this.userMessageFontWeight,
    required this.charMessageFontWeight,
    required this.userBubbleRadius,
    required this.charBubbleRadius,
    required this.showUserAvatar,
    required this.showCharAvatar,
    required this.showUserName,
    required this.showCharName,
    required this.chatFontName,
    required this.chatFontDataUrl,
    required this.chatFontSize,
    required this.chatLetterSpacing,
    required this.isSelectionMode,
    required this.batterySaver,
    required this.hideMessageId,
    required this.hideGenerationTime,
    required this.hideTokenCount,
    required this.disableSwipeRegeneration,
    required this.studioEnabled,
    required this.memoryEntries,
    required this.memoryDrafts,
    required this.sessionId,
    required this.isGenerating,
    required this.isGeneratingImage,
    required this.isPostGenRunning,
    required this.regenTargetId,
    this.continuationTargetId,
    required this.greetingTotal,
    required this.messages,
    required this.buildThemeMap,
  });

  final String charId;
  final String? charName;
  final String? charColor;
  final String? personaName;
  final String? charAvatarPath;
  final String? personaAvatarPath;
  final String? bgImagePath;
  final double bgBlur;
  final double bgDim;
  final double bgNoiseOpacity;
  final double bgNoiseIntensity;
  final double bottomInset;

  /// Height of the WebView box. Pushed with [bottomInset] so the page can
  /// subtract the part of the inset its own viewport already absorbed when the
  /// soft keyboard shrank it.
  final double viewportHeight;
  final double topInset;

  /// Rects of Flutter glass overlays (header, input pill, buttons) mirrored
  /// into the WebView as backdrop-blur strips. WebView-local coordinates.
  final List<ChatOverlayBlurRegion> blurRegions;
  final String? searchQuery;
  final int searchCurrentIndex;

  /// Bumped when the search matches were recounted over a changed message
  /// list. See [ChatWebViewSyncResult.rehighlightSearch].
  final int searchRevision;
  final String? chatLayout;
  final String? themeSyncKey;
  final double elementOpacity;
  final double elementBlur;
  final int uiFontWeight;
  final int userMessageFontWeight;
  final int charMessageFontWeight;
  final double userBubbleRadius;
  final double charBubbleRadius;
  final bool showUserAvatar;
  final bool showCharAvatar;
  final bool showUserName;
  final bool showCharName;
  final String? chatFontName;
  final String? chatFontDataUrl;
  final double chatFontSize;
  final double chatLetterSpacing;
  final bool isSelectionMode;
  final bool batterySaver;
  final bool hideMessageId;
  final bool hideGenerationTime;
  final bool hideTokenCount;
  final bool disableSwipeRegeneration;
  final bool studioEnabled;
  final List<dynamic> memoryEntries;
  final List<dynamic> memoryDrafts;
  final String? sessionId;
  final bool isGenerating;
  final bool isGeneratingImage;
  final bool isPostGenRunning;
  final String? regenTargetId;

  /// Id of the assistant message a continuation run extends, or null.
  /// Mirrors `ChatState.continuationTargetId`.
  final String? continuationTargetId;
  final int greetingTotal;
  final List<ChatMessage> messages;

  /// Computes the theme map from the current widget state. Lazy
  /// because it depends on `BuildContext` and we only want to do it
  /// when a theme-affecting field actually changed.
  final Map<String, String> Function() buildThemeMap;
}
