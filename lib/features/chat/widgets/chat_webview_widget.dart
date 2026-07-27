import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/active_regex_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../../core/state/persona_resolution.dart';
import '../../../../shared/theme/theme_font_provider.dart';
import '../../../../shared/theme/theme_preset.dart';
import '../bridge/chat_bridge_controller.dart';
import '../bridge/chat_overlay_blur_region.dart';
import '../bridge/chat_webview_bridge_host.dart';
import '../bridge/chat_webview_theme_builder.dart';
import '../../../core/models/chat_message.dart';
import '../../../shared/widgets/glaze_error_dialog.dart';
import '../../extensions/services/panel_host_service.dart';
import '../bridge/chat_bridge_registry.dart';
import '../chat_provider.dart';
import 'chat_message_sync.dart';
import 'chat_webview_build_listeners.dart';
import 'chat_webview_callbacks.dart';
import 'chat_webview_ext_block_callbacks.dart';
import 'chat_webview_initializer.dart';
import 'chat_webview_panel_refresher.dart';
import 'chat_webview_surface.dart';
import 'chat_webview_sync_dispatcher.dart';
import 'webview_callbacks.dart';

const String _kStreamingId = '__streaming__';
const Duration _kBridgeOpTimeout = Duration(seconds: 15);
const Duration _kWebViewInitTimeout = Duration(seconds: 45);
const Duration _kJsBridgeReadyTimeout = Duration(seconds: 30);
const Object _identityUnset = Object();

class ChatWebViewWidget extends ConsumerStatefulWidget {
  final String charId;
  final String? charName;
  final String? charColor;
  final String? personaName;
  final String? personaColor;
  final String? charAvatarPath;
  final String? personaAvatarPath;
  final String? bgImagePath;
  final double bgBlur;
  final double bgOpacity;
  final double bgNoiseOpacity;
  final double bgNoiseIntensity;
  final double bgDim;
  final String chatBgMode;
  final Color? chatBgColor;
  final List<ChatMessage> messages;
  final bool isGenerating;
  final bool isGeneratingImage;
  final bool isPostGenRunning;
  final double bottomInset;

  /// Height of the box this WebView is laid out in. Pushed alongside
  /// [bottomInset] so the page can tell how much of that inset its own viewport
  /// already absorbed (a soft keyboard that shrinks the WebView instead of
  /// overlaying it) and pad only the remainder.
  final double viewportHeight;
  final double topInset;

  /// Rects of the Flutter glass overlays (header, input pill, buttons) in
  /// WebView-local coordinates. Synced into the WebView (blurs the messages
  /// scrolling underneath) and painted as a BackdropFilter sandwich below
  /// the WebView (blurs the Flutter-side global background) — the widgets'
  /// own BackdropFilter cannot sample the platform view or anything under it.
  final List<ChatOverlayBlurRegion> blurRegions;
  final String? searchQuery;
  final int searchCurrentIndex;
  final String? chatLayout;

  /// Changes when preset colors/layout tokens affecting the WebView change.
  final String? themeSyncKey;
  final double elementOpacity;
  final double elementBlur;
  final int uiFontWeight;
  final int userMessageFontWeight;
  final int charMessageFontWeight;
  final double userBubbleRadius;
  final double charBubbleRadius;
  final BubbleGradient? userBubbleGradient;
  final BubbleGradient? charBubbleGradient;
  final double textBgOpacity;
  final bool showUserAvatar;
  final bool showCharAvatar;
  final bool showUserName;
  final bool showCharName;
  final int greetingTotal;
  final String? chatFontName;
  final String? chatFontDataUrl;
  final double chatFontSize;
  final double chatLetterSpacing;
  final List<dynamic> memoryEntries;
  final List<dynamic> memoryDrafts;
  final String? sessionId;
  final int visibleStartIndex;
  final String? regenTargetId;

  /// Id of the assistant message a continuation run extends, or null.
  /// Mirrors `ChatState.continuationTargetId`: while set, the streamed text
  /// grows that bubble instead of a separate typing placeholder.
  final String? continuationTargetId;
  final bool isSelectionMode;
  final bool batterySaver;
  final bool hideMessageId;
  final bool hideGenerationTime;
  final bool hideTokenCount;
  final bool disableSwipeRegeneration;

  /// Whether Studio is enabled for the current session. Gates the Studio-only
  /// "Re-run cleaner" per-message button in the WebView (hidden when off).
  final bool studioEnabled;

  // Callback objects
  final MessageActionsCallbacks messageActions;
  final EditActionsCallbacks editActions;
  final ImageGenCallbacks imageGenActions;
  final ScrollCallbacks scrollActions;
  final MiscCallbacks miscActions;

  const ChatWebViewWidget({
    super.key,
    required this.charId,
    this.charName,
    this.charColor,
    this.personaName,
    this.personaColor,
    this.charAvatarPath,
    this.personaAvatarPath,
    this.bgImagePath,
    this.bgBlur = 0.0,
    this.bgOpacity = 1.0,
    this.bgNoiseOpacity = 0.0,
    this.bgNoiseIntensity = 1.0,
    this.bgDim = 0.0,
    this.chatBgMode = 'inherit',
    this.chatBgColor,
    required this.messages,
    required this.isGenerating,
    this.isGeneratingImage = false,
    this.isPostGenRunning = false,
    this.bottomInset = 0,
    this.viewportHeight = 0,
    this.topInset = 0,
    this.blurRegions = const [],
    this.searchQuery,
    this.searchCurrentIndex = 0,
    this.chatLayout,
    this.themeSyncKey,
    this.elementOpacity = 0.8,
    this.elementBlur = 12,
    this.uiFontWeight = 400,
    this.userMessageFontWeight = 400,
    this.charMessageFontWeight = 400,
    this.userBubbleRadius = 18,
    this.charBubbleRadius = 18,
    this.userBubbleGradient,
    this.charBubbleGradient,
    this.textBgOpacity = 0.0,
    this.showUserAvatar = true,
    this.showCharAvatar = true,
    this.showUserName = true,
    this.showCharName = true,
    this.greetingTotal = 0,
    this.chatFontName,
    this.chatFontDataUrl,
    this.chatFontSize = 15.0,
    this.chatLetterSpacing = 0.0,
    this.memoryEntries = const [],
    this.memoryDrafts = const [],
    this.sessionId,
    this.visibleStartIndex = 0,
    this.regenTargetId,
    this.continuationTargetId,
    this.isSelectionMode = false,
    this.batterySaver = false,
    this.hideMessageId = false,
    this.hideGenerationTime = false,
    this.hideTokenCount = false,
    this.disableSwipeRegeneration = false,
    this.studioEnabled = false,
    this.messageActions = const MessageActionsCallbacks(),
    this.editActions = const EditActionsCallbacks(),
    this.imageGenActions = const ImageGenCallbacks(),
    this.scrollActions = const ScrollCallbacks(),
    this.miscActions = const MiscCallbacks(),
  });

  @override
  ConsumerState<ChatWebViewWidget> createState() => ChatWebViewWidgetState();
}

class ChatWebViewWidgetState extends ConsumerState<ChatWebViewWidget>
    with AutomaticKeepAliveClientMixin {
  ChatBridgeController? _bridge;
  bool _ready = false;
  bool _sessionSwitching = false;
  Future<void>? _initFuture;
  ChatWebViewWidget? _deferredSwitchFrom;
  bool _bridgeFailureNotified = false;
  VoidCallback? _clearBridgeRegistry;
  final ChatWebViewSyncState _syncState = ChatWebViewSyncState();
  late final ChatWebViewSyncDispatcher _syncDispatcher =
      ChatWebViewSyncDispatcher(state: _syncState);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _bindBridgeRegistry(widget.charId);
    // Keep-alive re-attach safety net: when the chat body is rebuilt (e.g. a
    // full-screen spinner during an import-driven session switch destroys and
    // recreates this widget), the underlying native WebView is reused by the
    // keep-alive instance and is already loaded. In that case the surface's
    // `onLoadStop` does not fire again, so init would never run and the WebView
    // shows a grey, unresponsive page until the app restarts. Schedule an init
    // kick once the bridge is wired; `_initWebView()` is idempotent
    // (`_initFuture ??=`), so it is a no-op if the surface already started it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _kickInitWhenReady());
  }

  void _bindBridgeRegistry(String charId) {
    final registry = ref.read(chatBridgeRegistryProvider(charId).notifier);
    // dispose() runs synchronously inside BuildOwner.lockState (finalizeTree
    // during drawFrame). Riverpod forbids mutating providers there and asserts
    // on schedulerPhase == persistentCallbacks / midFrameMicrotasks. Defer the
    // registry reset to the next event-loop task (schedulerPhase == idle) so it
    // lands after the build phase. `Future.microtask` would still run during
    // midFrameMicrotasks and assert, so the event queue is required here.
    _clearBridgeRegistry = () => Future(() => registry.state = null);
  }

  /// Polls for the bridge (set by the surface's `onWebViewCreated`) and runs
  /// the idempotent init once it exists. Bounded so it can never spin forever.
  Future<void> _kickInitWhenReady() async {
    for (var i = 0; i < 50; i++) {
      if (!mounted) return;
      if (_ready || _initFuture != null) return;
      if (_bridge != null) {
        unawaited(_initWebView());
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  ChatWebViewPanelRefresher _panelRefresher() => ChatWebViewPanelRefresher(
    ref: ref,
    bridge: _bridge,
    ready: () => _ready,
    isMounted: () => mounted,
    charId: widget.charId,
    messages: () => widget.messages,
  );

  Future<void> _refreshExtBlocksPanel(String sessionId, String messageId) {
    return _panelRefresher().refreshForMessage(sessionId, messageId);
  }

  Future<void> _syncExtBlockPanels() {
    return _panelRefresher().syncForSession(widget.sessionId);
  }

  /// Owns the chat WebView's bridge-side dependencies: the
  /// [JsBridgeService] handler implementations (generateText,
  /// injectPrompt, uninjectPrompt, triggerGeneration, playAudio,
  /// showToast, executeCommand), the permission gate, and the long-lived
  /// helper instances (audio bridge, toast controller, command registry,
  /// trigger handler, prompt injection notifier).
  late final ChatWebViewBridgeHost _bridgeHost = ChatWebViewBridgeHost(
    ref: ref,
    overlayContextResolver: () => context,
    currentSessionId: () => widget.sessionId,
    currentCharacterId: () => widget.charId,
  );

  @override
  void dispose() {
    // Unregister bridge so the service doesn't hold a stale reference.
    _clearBridgeRegistry?.call();
    // Drop interactive panel state for this character so the singleton
    // registry doesn't keep references to disposed bridge callbacks.
    PanelHostService.instance.disposeAll(charId: widget.charId);
    // Release long-lived resources owned by the bridge host (audio
    // player, etc.). Errors are swallowed; teardown must not throw.
    _bridgeHost.dispose().catchError((Object _) {});
    super.dispose();
  }

  Future<void> _initWebView() {
    return _initFuture ??= _initWebViewOnce();
  }

  Future<void> _waitForJsBridgeReady() async {
    final bridge = _bridge;
    if (bridge == null) return;

    // Fast path: JS already fired onWebViewReady (keep-alive preload case —
    // the page was loaded before the chat screen opened).
    final alreadyReady = await bridge.evalJsWithResult(
      'typeof window.bridge !== "undefined" && window.bridge != null',
    );
    if (alreadyReady == true) return;

    // Slow path: race between the JS-side onWebViewReady signal (event-driven)
    // and a polling fallback. The event wins on normal loads; the poll catches
    // the race where JS fired onWebViewReady before Dart installed the handler.
    final completer = Completer<void>();
    final prevOnReady = bridge.onReady;
    bridge.onReady = () {
      bridge.onReady = prevOnReady;
      if (!completer.isCompleted) completer.complete();
      prevOnReady?.call();
    };

    // Polling fallback: re-check window.bridge every 200 ms independently of
    // the event so we don't miss a signal that arrived before the callback was
    // wired (can happen on iOS keep-alive WebView re-attach).
    unawaited(() async {
      final deadline = DateTime.now().add(_kJsBridgeReadyTimeout);
      while (!completer.isCompleted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (completer.isCompleted) return;
        final ready = await bridge.evalJsWithResult(
          'typeof window.bridge !== "undefined" && window.bridge != null',
        );
        if (ready == true && !completer.isCompleted) completer.complete();
      }
    }());

    try {
      await completer.future.timeout(
        _kJsBridgeReadyTimeout,
        onTimeout: () {
          throw TimeoutException(
            'Chat WebView JS bridge did not initialize within '
            '${_kJsBridgeReadyTimeout.inSeconds}s',
          );
        },
      );
    } finally {
      // Restore the previous callback if we were disposed before the signal.
      if (!completer.isCompleted) bridge.onReady = prevOnReady;
    }
  }

  Future<void> _initWebViewOnce() async {
    final bridge = _bridge;
    if (bridge == null) return;
    final initSessionId = widget.sessionId;
    try {
      await _waitForJsBridgeReady();
      // The WebView is kept alive across chats, so the JS header tracker still
      // holds the previous chat's hidden state and scroll baseline. Clear both
      // before the initial render, or the load's jump to the bottom reads as a
      // downward scroll and this chat opens with its header already gone.
      await _showChatHeader(bridge);
      await ChatWebViewInitializer(
        ref: ref,
        bridge: bridge,
        input: ChatWebViewInitInput(
          charId: widget.charId,
          sessionId: widget.sessionId,
          charName: widget.charName,
          charColor: widget.charColor,
          personaName: widget.personaName,
          chatLayout: widget.chatLayout,
          charAvatarPath: widget.charAvatarPath,
          personaAvatarPath: widget.personaAvatarPath,
          greetingTotal: widget.greetingTotal,
          bgImagePath: widget.bgImagePath,
          bgBlur: widget.bgBlur,
          bgOpacity: widget.bgOpacity,
          bgNoiseOpacity: widget.bgNoiseOpacity,
          bgNoiseIntensity: widget.bgNoiseIntensity,
          chatFontName: widget.chatFontName,
          chatFontDataUrl: widget.chatFontDataUrl,
          chatFontSize: widget.chatFontSize,
          chatLetterSpacing: widget.chatLetterSpacing,
          batterySaver: widget.batterySaver,
          hideMessageId: widget.hideMessageId,
          hideGenerationTime: widget.hideGenerationTime,
          hideTokenCount: widget.hideTokenCount,
          disableSwipeRegeneration: widget.disableSwipeRegeneration,
          studioEnabled: widget.studioEnabled,
          messages: widget.messages,
          visibleStartIndex: widget.visibleStartIndex,
          memoryEntries: widget.memoryEntries,
          memoryDrafts: widget.memoryDrafts,
          bottomInset: widget.bottomInset,
          viewportHeight: widget.viewportHeight,
          topInset: widget.topInset,
          blurRegions: widget.blurRegions,
          searchQuery: widget.searchQuery,
          searchCurrentIndex: widget.searchCurrentIndex,
          isSelectionMode: widget.isSelectionMode,
          isGenerating: widget.isGenerating,
          isGeneratingImage: widget.isGeneratingImage,
          isPostGenRunning: widget.isPostGenRunning,
        ),
        onReady: () => _ready = true,
        onSyncExtBlockPanels: _syncExtBlockPanels,
        applyTheme: _applyThemeToBridge,
      ).run().timeout(_kWebViewInitTimeout);
    } on TimeoutException catch (e, st) {
      _handleWebViewFailure(e, st, phase: 'init');
      return;
    } catch (e, st) {
      _handleWebViewFailure(e, st, phase: 'init');
      return;
    } finally {
      if (!_ready) _initFuture = null;
    }

    if (!mounted) return;
    // Init can take longer than the rebaseline window opened above, and the
    // list settles for a few more frames after it. Re-arm once everything is in
    // place so the chat is guaranteed to open with the header showing.
    await _showChatHeader(bridge);
    // Init captures widget fields before async setup completes. On cold start,
    // the active persona can resolve during that window, so push the latest
    // identity once the bridge is ready instead of leaving rendered user
    // messages as the default "You" until a later chat/persona switch.
    await _bridgeOp(_applyResolvedIdentity(), label: 'setIdentity');
    // The provider listener for info_blocks can fire before the WebView DOM is
    // ready. Do an awaited sync immediately after init so existing blocks from
    // the DB are painted on the first chat open, not only after re-entering.
    await _bridgeOp(_syncExtBlockPanels(), label: 'syncExtBlockPanels');
    final deferred = _deferredSwitchFrom;
    _deferredSwitchFrom = null;
    if (deferred != null) {
      unawaited(_applySessionSwitch(deferred));
    } else if (initSessionId != widget.sessionId) {
      unawaited(_syncCurrentSessionToBridge());
    }
  }

  void _handleWebViewFailure(
    Object e,
    StackTrace? st, {
    required String phase,
  }) {
    debugPrint('[ChatWebView] $phase failed: $e\n$st');
    if (!mounted) return;
    setState(() => _sessionSwitching = false);
    if (_bridgeFailureNotified) return;
    _bridgeFailureNotified = true;
    GlazeErrorDialog.show(context, e, prefix: 'Chat view failed to load');
  }

  /// Re-shows the chat header and re-baselines the JS hide-on-scroll tracker.
  /// Awaited (not fire-and-forget) so the rebaseline window is armed before the
  /// list is filled and jumped to the bottom, but never routed through
  /// [_bridgeOp]: this is cosmetic, and a failure must not surface as a "chat
  /// failed to load" dialog.
  Future<void> _showChatHeader(ChatBridgeController bridge) async {
    try {
      await bridge.showHeader().timeout(_kBridgeOpTimeout);
    } catch (e) {
      debugPrint('[ChatWebView] showHeader failed: $e');
    }
  }

  Future<void> _bridgeOp(Future<void> op, {required String label}) async {
    try {
      await op.timeout(_kBridgeOpTimeout);
    } on TimeoutException catch (e, st) {
      debugPrint('[ChatWebView] bridge op timed out: $label');
      _handleWebViewFailure(e, st, phase: label);
    } catch (e, st) {
      debugPrint('[ChatWebView] bridge op failed ($label): $e\n$st');
      _handleWebViewFailure(e, st, phase: label);
    }
  }

  Future<void> _syncCurrentSessionToBridge() async {
    final bridge = _bridge;
    if (bridge == null || !_ready) return;
    try {
      if (mounted) setState(() => _sessionSwitching = true);
      // Same reasoning as on open: the replace below jumps the list, which the
      // header tracker would otherwise read as the user scrolling down.
      await _showChatHeader(bridge);
      await _bridgeOp(bridge.clearAll(), label: 'clearAll');
      await _bridgeOp(
        bridge.setMessages(
          widget.messages,
          visibleStartIndex: widget.visibleStartIndex,
        ),
        label: 'setMessages',
      );
      unawaited(_syncExtBlockPanels());
      await _bridgeOp(bridge.scrollToBottom(), label: 'scrollToBottom');
    } finally {
      if (mounted) setState(() => _sessionSwitching = false);
    }
  }

  void _bindBridgeCallbacks() {
    final bridge = _bridge;
    if (bridge == null || !mounted) return;
    final callbacks = ChatWebViewCallbacks(
      ref: ref,
      charId: widget.charId,
      messageActions: widget.messageActions,
      editActions: widget.editActions,
      imageGenActions: widget.imageGenActions,
      scrollActions: widget.scrollActions,
      miscActions: widget.miscActions,
    );
    bridge.onMessageContext = callbacks.onMessageContext;
    bridge.onSwipe = callbacks.onSwipe;
    bridge.onAgentSwipe = callbacks.onAgentSwipe;
    bridge.onChangeGreeting = callbacks.onChangeGreeting;
    bridge.onHeaderScroll = callbacks.onHeaderScroll;
    bridge.onScrollToBottomVisibility = callbacks.onScrollToBottomVisibility;
    bridge.onRegenerate = callbacks.onRegenerate;
    bridge.onRerunCleaner = callbacks.onRerunCleaner;
    bridge.onSelectionAction = callbacks.onSelectionAction;
    bridge.onSelectionChange = callbacks.onSelectionChange;
    bridge.onEditSave = callbacks.onEditSave;
    bridge.onEditCancel = callbacks.onEditCancel;
    bridge.onEditFocusChange = callbacks.onEditFocusChange;
    bridge.onImageClick = callbacks.onImageClick;
    bridge.onImgDownload = callbacks.onImgDownload;
    bridge.onGuidedSwipe = callbacks.onGuidedSwipe;
    bridge.onMemoryClick = callbacks.onMemoryClick;
    bridge.onToggleHidden = callbacks.onToggleHidden;
    bridge.onToggleImageHidden = callbacks.onToggleImageHidden;
    bridge.onInjectClick = callbacks.onInjectClick;
    bridge.onImgRetry = callbacks.onImgRetry;
    bridge.onImgFind = callbacks.onImgFind;
    bridge.onImgRegen = callbacks.onImgRegen;
    bridge.onImgOptions = callbacks.onImgOptions;
    bridge.onImgCancel = callbacks.onImgCancel;
    bridge.onStop = callbacks.onStop;
    bridge.onLinkClick = callbacks.onLinkClick;
    bridge.onLoadMore = callbacks.onLoadMore;

    final extBlocks = ChatWebViewExtBlockCallbacks(
      ref: ref,
      charId: widget.charId,
      sessionId: widget.sessionId,
      context: context,
      isMounted: () => mounted,
      refreshPanel: _refreshExtBlocksPanel,
    );
    bridge.onExtBlocksRunAll = extBlocks.onRunAll();
    bridge.onExtBlockStop = extBlocks.onStop();
    bridge.onExtBlockRegen = extBlocks.onRegen();
    bridge.onExtBlockRegenImage = extBlocks.onRegenImage();
    bridge.onExtBlockEdit = extBlocks.onEdit();
    bridge.onExtBlockDelete = extBlocks.onDelete();
  }

  Future<void> applyIdentity({
    Object? charName = _identityUnset,
    Object? charColor = _identityUnset,
    Object? personaName = _identityUnset,
    Object? charAvatarPath = _identityUnset,
    Object? personaAvatarPath = _identityUnset,
    Object? greetingTotal = _identityUnset,
  }) {
    final bridge = _bridge;
    if (bridge == null || !_ready) return Future.value();
    return bridge.setIdentity(
      charName: charName == _identityUnset
          ? widget.charName
          : charName as String?,
      charColor: charColor == _identityUnset
          ? widget.charColor
          : charColor as String?,
      personaName: personaName == _identityUnset
          ? widget.personaName
          : personaName as String?,
      layout: widget.chatLayout,
      charAvatarPath: charAvatarPath == _identityUnset
          ? widget.charAvatarPath
          : charAvatarPath as String?,
      personaAvatarPath: personaAvatarPath == _identityUnset
          ? widget.personaAvatarPath
          : personaAvatarPath as String?,
      greetingTotal: greetingTotal == _identityUnset
          ? widget.greetingTotal
          : greetingTotal as int?,
    );
  }

  Future<void> _applyResolvedIdentity() {
    final bridge = _bridge;
    if (bridge == null || !_ready || !mounted) return Future.value();
    final character = ref.read(characterByIdProvider(widget.charId));
    final effectivePersona = ref.read(
      effectivePersonaForChatProvider((
        charId: widget.charId,
        sessionId: widget.sessionId,
      )),
    );
    return bridge.setIdentity(
      charName: character?.name ?? widget.charName,
      charColor: character?.color ?? widget.charColor,
      personaName: effectivePersona?.name ?? widget.personaName,
      layout: widget.chatLayout,
      charAvatarPath: character?.avatarPath ?? widget.charAvatarPath,
      personaAvatarPath:
          effectivePersona?.avatarPath ?? widget.personaAvatarPath,
      greetingTotal: character == null
          ? widget.greetingTotal
          : ((character.firstMes?.isNotEmpty == true ? 1 : 0) +
                character.alternateGreetings.where((g) => g.isNotEmpty).length),
    );
  }

  Future<void> _applySessionSwitch(ChatWebViewWidget old) async {
    final bridge = _bridge;
    if (bridge == null) return;
    if (!_ready) {
      _deferredSwitchFrom = old;
      return;
    }

    // Drop any interactive panels from the previous session before clearing
    // the WebView DOM. JS-side `clearAll()` also closes panels, but the
    // Dart-side registry has to be reset so the next `openPanel` call can
    // bind fresh handlers on the (potentially new) bridge.
    unawaited(PanelHostService.instance.disposeAll(charId: old.charId));
    unawaited(bridge.evalJs('window.bridge?.clearAll();'));
    try {
      if (mounted) setState(() => _sessionSwitching = true);
      // Same reasoning as on open: the replace below jumps the list, which the
      // header tracker would otherwise read as the user scrolling down.
      await _showChatHeader(bridge);
      if (widget.charId != old.charId) {
        await _bridgeOp(
          bridge.setIdentity(
            charName: widget.charName,
            charColor: widget.charColor,
            personaName: widget.personaName,
            layout: widget.chatLayout,
            charAvatarPath: widget.charAvatarPath,
            personaAvatarPath: widget.personaAvatarPath,
            greetingTotal: widget.greetingTotal,
          ),
          label: 'setIdentity',
        );
        await _bridgeOp(_applyThemeToBridge(), label: 'applyTheme');
        await _bridgeOp(
          bridge.setBackgroundNoise(
            widget.bgNoiseOpacity,
            widget.bgNoiseIntensity,
          ),
          label: 'setBackgroundNoise',
        );
        await _bridgeOp(
          bridge.setChatFont(
            fontName: widget.chatFontName,
            fontDataUrl: widget.chatFontDataUrl,
            fontSize: widget.chatFontSize,
            letterSpacing: widget.chatLetterSpacing,
          ),
          label: 'setChatFont',
        );
      } else {
        await _bridgeOp(
          bridge.setIdentity(
            charName: widget.charName,
            charColor: widget.charColor,
            personaName: widget.personaName,
            layout: widget.chatLayout,
            charAvatarPath: widget.charAvatarPath,
            personaAvatarPath: widget.personaAvatarPath,
            greetingTotal: widget.greetingTotal,
          ),
          label: 'setIdentity',
        );
      }

      await _bridgeOp(bridge.clearAll(), label: 'clearAll');
      await _bridgeOp(
        bridge.setMessages(
          widget.messages,
          visibleStartIndex: widget.visibleStartIndex,
        ),
        label: 'setMessages',
      );
      unawaited(_syncExtBlockPanels());
      await _bridgeOp(bridge.scrollToBottom(), label: 'scrollToBottom');
    } finally {
      if (mounted) setState(() => _sessionSwitching = false);
    }
    _syncState.wasGenerating = widget.isGenerating;
    _syncState.streamingSent = false;
  }

  ChatWebViewWidgetFields _fieldsFor(ChatWebViewWidget w) {
    return ChatWebViewWidgetFields(
      charId: w.charId,
      charName: w.charName,
      charColor: w.charColor,
      personaName: w.personaName,
      charAvatarPath: w.charAvatarPath,
      personaAvatarPath: w.personaAvatarPath,
      bgImagePath: w.bgImagePath,
      bgBlur: w.bgBlur,
      bgOpacity: w.bgOpacity,
      bgDim: w.bgDim,
      bgNoiseOpacity: w.bgNoiseOpacity,
      bgNoiseIntensity: w.bgNoiseIntensity,
      bottomInset: w.bottomInset,
      viewportHeight: w.viewportHeight,
      topInset: w.topInset,
      blurRegions: w.blurRegions,
      searchQuery: w.searchQuery,
      searchCurrentIndex: w.searchCurrentIndex,
      chatLayout: w.chatLayout,
      themeSyncKey: w.themeSyncKey,
      elementOpacity: w.elementOpacity,
      elementBlur: w.elementBlur,
      uiFontWeight: w.uiFontWeight,
      userMessageFontWeight: w.userMessageFontWeight,
      charMessageFontWeight: w.charMessageFontWeight,
      userBubbleRadius: w.userBubbleRadius,
      charBubbleRadius: w.charBubbleRadius,
      showUserAvatar: w.showUserAvatar,
      showCharAvatar: w.showCharAvatar,
      showUserName: w.showUserName,
      showCharName: w.showCharName,
      chatFontName: w.chatFontName,
      chatFontDataUrl: w.chatFontDataUrl,
      chatFontSize: w.chatFontSize,
      chatLetterSpacing: w.chatLetterSpacing,
      isSelectionMode: w.isSelectionMode,
      batterySaver: w.batterySaver,
      hideMessageId: w.hideMessageId,
      hideGenerationTime: w.hideGenerationTime,
      hideTokenCount: w.hideTokenCount,
      disableSwipeRegeneration: w.disableSwipeRegeneration,
      studioEnabled: w.studioEnabled,
      memoryEntries: w.memoryEntries,
      memoryDrafts: w.memoryDrafts,
      sessionId: w.sessionId,
      isGenerating: w.isGenerating,
      isGeneratingImage: w.isGeneratingImage,
      isPostGenRunning: w.isPostGenRunning,
      regenTargetId: w.regenTargetId,
      continuationTargetId: w.continuationTargetId,
      greetingTotal: w.greetingTotal,
      messages: w.messages,
      buildThemeMap: _buildThemeMap,
    );
  }

  @override
  void didUpdateWidget(ChatWebViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.charId != oldWidget.charId) {
      _clearBridgeRegistry?.call();
      _bindBridgeRegistry(widget.charId);
    }
    if (!_ready &&
        (widget.charId != oldWidget.charId ||
            widget.sessionId != oldWidget.sessionId)) {
      _deferredSwitchFrom = oldWidget;
    }
    final result = _syncDispatcher.dispatch(
      bridge: _bridge,
      old: _fieldsFor(oldWidget),
      current: _fieldsFor(widget),
      oldMessages: oldWidget.messages,
      newMessages: widget.messages,
      streamingId: _kStreamingId,
      onSyncExtBlockPanels: _syncExtBlockPanels,
      appendMessage: (m) async {
        await _bridge?.appendMessage(m);
      },
      buildStreamingPlaceholder: () => ChatMessage(
        id: _kStreamingId,
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isTyping: true,
      ),
      ready: _ready,
      isImpersonating: ref
          .read(impersonationStateProvider(widget.charId))
          .active,
    );
    if (result.sessionSwitched) {
      // Raise the cover synchronously (build runs right after didUpdateWidget)
      // so the very first frame of the new session hides the kept-alive native
      // surface's stale content, instead of waiting for the async switch below
      // to flip it a frame or two later.
      _sessionSwitching = true;
      if (!_ready) {
        _deferredSwitchFrom = oldWidget;
      } else {
        unawaited(_applySessionSwitch(oldWidget));
      }
      return;
    }
    if (result.runMessageSync) {
      _syncMessages(oldWidget.messages);
      unawaited(_syncExtBlockPanels());
    }
    if (result.appendPlaceholder && result.placeholder != null) {
      unawaited(_bridge?.appendMessage(result.placeholder!));
      _syncDispatcher.onPlaceholderAppended();
    }
  }

  static const _messageSync = ChatMessageSync();

  void _syncMessages(List<ChatMessage> oldMsgs) {
    _messageSync.sync(
      bridge: _bridge,
      oldMsgs: oldMsgs,
      newMsgs: widget.messages,
      visibleStartIndex: widget.visibleStartIndex,
      isGenerating: widget.isGenerating,
      sessionSwitching: _sessionSwitching,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final character = ref.watch(characterByIdProvider(widget.charId));
    final effectivePersonaProvider = effectivePersonaForChatProvider((
      charId: widget.charId,
      sessionId: widget.sessionId,
    ));
    final effectivePersona = ref.watch(effectivePersonaProvider);
    ref.listen(effectivePersonaProvider, (prev, next) {
      if (prev?.id == next?.id &&
          prev?.name == next?.name &&
          prev?.avatarPath == next?.avatarPath) {
        return;
      }
      if (_bridge == null || !_ready) return;
      unawaited(_bridgeOp(_applyResolvedIdentity(), label: 'setIdentity'));
    });
    final displayRegexes = ref.watch(displayRegexesProvider).value ?? [];

    if (_bridge != null) {
      _bindBridgeCallbacks();
      _bridge!.setRegexContext(displayRegexes, character, effectivePersona);
      // Refresh the origin ("Created on" / "Branched on") marker before any
      // message sync dispatches, so a full setMessages picks up the current
      // session's creation/branch stamp.
      _bridge!.chatOrigin = ChatBridgeController.originMarkerFor(
        ref.watch(chatProvider(widget.charId)).value?.session,
      );
    }

    ChatWebViewBuildListeners(
      ref: ref,
      bridge: _bridge,
      ready: () => _ready,
      syncState: _syncState,
      streamingId: _kStreamingId,
      charId: widget.charId,
      sessionId: widget.sessionId,
      messages: widget.messages,
      regenTargetId: widget.regenTargetId,
      continuationTargetId: widget.continuationTargetId,
      visibleStartIndex: widget.visibleStartIndex,
      onRefreshExtBlocksPanel: _refreshExtBlocksPanel,
      onSyncExtBlockPanels: _syncExtBlockPanels,
    ).attach();

    // 'inherit' reuses the global background image; 'custom' uses the chat's
    // own image; 'color'/'avatar' don't need decoded bytes here.
    final bgImageBytes = switch (widget.chatBgMode) {
      'custom' => ref.watch(chatBgImageBytesProvider),
      'inherit' => ref.watch(effectiveBgImageBytesProvider),
      _ => null,
    };

    return ChatWebViewSurface(
      bridgeHost: _bridgeHost,
      charId: widget.charId,
      sessionId: widget.sessionId,
      messageActions: widget.messageActions,
      editActions: widget.editActions,
      imageGenActions: widget.imageGenActions,
      scrollActions: widget.scrollActions,
      miscActions: widget.miscActions,
      isMounted: () => mounted,
      sessionSwitching: _sessionSwitching,
      refreshPanel: _refreshExtBlocksPanel,
      bgImageBytes: bgImageBytes,
      bgOpacity: widget.bgOpacity,
      bgBlur: widget.bgBlur,
      bgDim: widget.bgDim,
      chatBgMode: widget.chatBgMode,
      chatBgColor: widget.chatBgColor,
      chatBgAvatarPath: widget.charAvatarPath,
      bottomInset: widget.bottomInset,
      onBridgeReady: (ChatBridgeController b) => _bridge = b,
      onInitWebView: _initWebView,
    );
  }

  Map<String, String> _buildThemeMap() {
    return ChatWebViewThemeBuilder.build(
      context,
      ChatWebViewThemeInput(
        elementOpacity: widget.elementOpacity,
        elementBlur: widget.elementBlur,
        chatFontSize: widget.chatFontSize,
        chatLayout: widget.chatLayout,
        bgDim: widget.bgDim,
        uiFontWeight: widget.uiFontWeight,
        userMessageFontWeight: widget.userMessageFontWeight,
        charMessageFontWeight: widget.charMessageFontWeight,
        userBubbleRadius: widget.userBubbleRadius,
        charBubbleRadius: widget.charBubbleRadius,
        userBubbleGradient: widget.userBubbleGradient,
        charBubbleGradient: widget.charBubbleGradient,
        textBgOpacity: widget.textBgOpacity,
        showUserAvatar: widget.showUserAvatar,
        showCharAvatar: widget.showCharAvatar,
        showUserName: widget.showUserName,
        showCharName: widget.showCharName,
      ),
    );
  }

  Future<void> _applyThemeToBridge() async {
    await _bridge?.applyTheme(_buildThemeMap());
  }

  /// True once the WebView's JS bridge has fully initialized and the chat is
  /// rendered. Callers wanting to drive the view (e.g. scroll-to-message from a
  /// notification tap) should gate on this.
  bool get isReady => _ready;

  List<TriggeredEntry> triggeredRegexesFor(String messageId) =>
      _bridge?.triggeredRegexesFor(messageId) ?? const [];

  Future<void> scrollToBottom({bool smooth = false}) {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.scrollToBottom(smooth: smooth);
  }

  /// Arm a one-shot "stick to bottom on the next append" so sending a message
  /// scrolls the view down even if the user had scrolled up. Called before the
  /// new message is dispatched so the flag is set ahead of the append.
  Future<void> requestScrollToBottomOnAppend() {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.requestScrollToBottomOnAppend();
  }

  /// Re-asserts the WebView's bottom padding to [px]. Used on app resume to
  /// reconcile a stale padding: the native WebView freezes its JS while
  /// backgrounded, so an inset change pushed during the background transition
  /// can be dropped. The JS side no-ops when the padding already matches, so
  /// this is cheap to call defensively.
  Future<void> applyBottomInset(double px, {double viewportHeight = 0}) {
    final b = _bridge;
    if (b == null || !_ready) return Future.value();
    return b.setBottomPadding(px, viewportHeight: viewportHeight);
  }

  Future<void> scrollToMessage(String id, {bool highlight = false}) {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.scrollToMessage(id, highlight: highlight);
  }

  Future<void> setSearch(String q, int i) {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.setSearch(query: q, activeIndex: i);
  }

  Future<void> toggleMessageSelection(String id) {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.toggleMessageSelection(id);
  }
}
