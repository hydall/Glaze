import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/utils/image_src.dart';
import '../../core/utils/platform_paths.dart';
import 'editing_message_provider.dart';

import '../../core/state/character_provider.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/memory_settings_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/shell/desktop/desktop_layout_provider.dart'
    show isDesktopLayout;
import 'widgets/message_actions.dart';
import '../../shared/theme/theme_font_provider.dart';
import '../../shared/theme/theme_preset.dart';
import '../../shared/theme/theme_provider.dart';

import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/image_viewer.dart';
import '../character_list/character_detail_screen.dart';
import '../personas/persona_list_screen.dart';
import '../presets/preset_editor_screen.dart';
import '../settings/api_list_provider.dart';
import '../settings/api_settings_screen.dart';
import '../settings/app_settings_provider.dart';
import 'chat_drawer_controller.dart'
    show ChatDrawerController, DrawerPanel, kKeyboardHeightPref;
import 'chat_provider.dart';
import 'controllers/chat_message_selection_controller.dart';
import 'chat_search_delegate.dart';
import 'chat_state.dart';
import 'state/chat_body_selectors.dart';
import 'state/memory_activity_provider.dart';
import 'bridge/chat_overlay_blur_region.dart';
import 'widgets/chat_blur_region_tracker.dart';
import 'widgets/chat_header.dart';
import 'widgets/chat_input_bar.dart';
import 'widgets/magic_drawer.dart';
import 'widgets/memory_activity_card.dart';
import 'widgets/post_cleaner_status_card.dart';
import 'widgets/post_gen_status_card.dart';
import 'widgets/studio_status_card.dart';
import 'widgets/quick_replies_panel.dart';
import 'widgets/chat_webview_widget.dart';
import 'widgets/triggered_items_sheet.dart';
import 'widgets/webview_callbacks.dart';
import '../../core/models/chat_message.dart';
import '../../core/state/db_provider.dart';
import 'widgets/session_lifecycle_tracker.dart';

String _chatWebViewThemeSyncKey(ThemePreset preset, String chatLayout) {
  return [
    preset.id,
    preset.accentColor,
    preset.uiColor,
    preset.userBubbleColor,
    preset.charBubbleColor,
    preset.userBubbleGradient,
    preset.charBubbleGradient,
    preset.userTextColor,
    preset.charTextColor,
    preset.userQuoteColor,
    preset.charQuoteColor,
    preset.userItalicColor,
    preset.charItalicColor,
    preset.elementOpacity,
    preset.elementBlur,
    preset.uiFontWeight,
    preset.userMessageFontWeight,
    preset.charMessageFontWeight,
    preset.userBubbleRadius,
    preset.charBubbleRadius,
    preset.showUserAvatar,
    preset.showCharAvatar,
    preset.showUserName,
    preset.showCharName,
    chatLayout,
  ].join('|');
}

class ChatScreen extends ConsumerStatefulWidget {
  final String charId;
  final int? initialSessionIndex;
  final bool forceNewSession;

  /// When set (e.g. opening from a "new message" notification tap), the chat
  /// scrolls to and briefly flashes this message once the WebView is ready.
  final String? targetMessageId;

  const ChatScreen({
    super.key,
    required this.charId,
    this.initialSessionIndex,
    this.forceNewSession = false,
    this.targetMessageId,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SingleTickerProviderStateMixin {
  bool _sessionApplied = false;
  bool _sessionSwitchPending = false;
  int _applyEpoch = 0;
  // True once `_ChatBody` (and the keep-alive WebView) has been rendered at
  // least once. After that, an in-chat session switch overlays a spinner
  // instead of destroying the body, so the WebView is never recreated.
  bool _everBuiltBody = false;
  bool _isHeaderHidden = false;
  late final ChatDrawerController _drawerCtrl;
  late final ChatSearchDelegate _search;

  @override
  void initState() {
    super.initState();
    _drawerCtrl = ChatDrawerController(
      vsync: this,
      readKeyboardHeight: () async {
        final prefs = await ref.read(sharedPreferencesProvider.future);
        return prefs.getDouble(kKeyboardHeightPref) ?? 0;
      },
      persistKeyboardHeight: (h) async {
        final prefs = await ref.read(sharedPreferencesProvider.future);
        await prefs.setDouble(kKeyboardHeightPref, h);
      },
    );
    _search = ChatSearchDelegate();
    // The delegate holds the query, the match list and the active match index.
    // Nothing else rebuilds on those: without this listener, `searchNext` /
    // `searchPrev` only mutated the delegate and the new active index never
    // reached the WebView, so the prev/next buttons looked dead and closing
    // search left the highlight behind until some unrelated rebuild.
    _search.addListener(_onSearchChanged);
    if (widget.forceNewSession || widget.initialSessionIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applySessionPreference();
      });
    }
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _drawerCtrl.dispose();
    _search.removeListener(_onSearchChanged);
    _search.dispose();
    super.dispose();
  }

  Future<void> _applySessionPreference() async {
    if (_sessionApplied) return;
    _sessionApplied = true;
    final epoch = ++_applyEpoch;
    final needsSwitch =
        widget.forceNewSession || widget.initialSessionIndex != null;
    if (needsSwitch && mounted) {
      setState(() => _sessionSwitchPending = true);
    }
    try {
      // Wait for chatProvider's initial build to complete before switching,
      // otherwise the build's final state may overwrite our switchSession.
      await ref.read(chatProvider(widget.charId).future);
      if (!mounted || epoch != _applyEpoch) return;
      final notifier = ref.read(chatProvider(widget.charId).notifier);
      if (widget.forceNewSession) {
        await notifier.createNewSession();
      } else if (widget.initialSessionIndex != null) {
        await notifier
            .switchSession(widget.initialSessionIndex!)
            .timeout(const Duration(seconds: 30));
      }
      if (!mounted || epoch != _applyEpoch) return;
    } on TimeoutException catch (e) {
      if (mounted && epoch == _applyEpoch) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: 'Failed to open chat session',
        );
      }
    } catch (e) {
      if (mounted && epoch == _applyEpoch) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: 'Failed to open chat session',
        );
      }
    } finally {
      if (mounted && epoch == _applyEpoch && _sessionSwitchPending) {
        setState(() => _sessionSwitchPending = false);
      }
    }
  }

  @override
  void didUpdateWidget(ChatScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialSessionIndex != old.initialSessionIndex ||
        widget.forceNewSession != old.forceNewSession ||
        widget.charId != old.charId) {
      _sessionApplied = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applySessionPreference();
      });
    }
  }

  void _onScrollDirection(ScrollDirection direction) {
    // Driven by a JS callback (see `onHeaderScroll`), which can land after the
    // chat was left — including the visibility push the bridge sends on open.
    if (!mounted) return;
    if (direction == ScrollDirection.reverse && !_isHeaderHidden) {
      setState(() => _isHeaderHidden = true);
    } else if (direction == ScrollDirection.forward && _isHeaderHidden) {
      setState(() => _isHeaderHidden = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final charId = widget.charId;
    final chatStateAsync = ref.watch(chatProvider(charId));
    final chatState = chatStateAsync.value;

    final character = ref.watch(characterByIdProvider(charId));
    final title = character?.name ?? 'Chat';
    final session = chatState?.session;
    final customSessionName = session?.sessionVars['sessionName']?.trim();
    final sessionName = session != null
        ? (customSessionName != null && customSessionName.isNotEmpty
              ? customSessionName
              : 'Session #${session.sessionIndex + 1}')
        : 'status_connecting'.tr();
    final sessionIndex = chatState?.session?.sessionIndex ?? 0;

    final appSettings = ref.watch(appSettingsProvider).value;
    final virtualKeyboardSend = appSettings?.virtualKeyboardSend ?? false;
    final enterToSend = appSettings?.enterToSend ?? true;
    final batterySaver = appSettings?.batterySaver ?? false;
    _drawerCtrl.setBatterySaverMode(batterySaver);

    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    _drawerCtrl.handleKeyboardFrame(keyboardHeight);

    if (_drawerCtrl.switchingToDrawer && keyboardHeight == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _drawerCtrl.checkSwitchingTransition(keyboardHeight);
      });
    }

    if (keyboardHeight > 0 &&
        _drawerCtrl.drawerOpen &&
        !_drawerCtrl.switchingToDrawer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _drawerCtrl.checkDrawerCollision(keyboardHeight);
      });
    }

    return SessionLifecycleTracker(
      charId: charId,
      // Chat is always reached via `context.go('/chat/...')`, which replaces the
      // navigation stack — so a real pop has nothing beneath it and the OS would
      // close the app. We must NOT add our own `PopScope` here: `GlazeScaffold`
      // already wraps its body in a `PopScope` (canPop is false because showBack
      // is true) and routes the intercepted back gesture to `onBack`. Flutter
      // invokes the callbacks of *every* registered PopEntry on the route, so a
      // second `PopScope` would fire alongside `onBack` and still navigate away
      // even after we dismissed an overlay. All back handling lives in `onBack`.
      child: GlazeScaffold(
        extendBodyBehindHeader: true,
        resizeToAvoidBottomInset: false,
        // The body is a full-screen chat WebView; the header's glass blur is
        // reproduced by an in-WebView CSS strip (mirrored via the 'header'
        // blur region in _measureBlurRegions), so drop the Flutter blur pass.
        headerBlurViaWebView: true,
        hideHeader: _isHeaderHidden,
        title: title,
        titleWidget: _search.showSearch
            ? TextField(
                controller: _search.searchController,
                autofocus: true,
                style: TextStyle(color: context.cs.onSurface, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'search_messages'.tr(),
                  hintStyle: TextStyle(
                    color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  suffixIcon: _search.searchQuery.isNotEmpty
                      ? IconButton(
                          icon: Icon(
                            Icons.close,
                            color: context.cs.onSurface,
                            size: 20,
                          ),
                          onPressed: () {
                            _search.closeSearch();
                          },
                        )
                      : null,
                ),
                onChanged: (q) {
                  _search.search(q, chatState?.messages ?? []);
                },
              )
            : (character != null
                  ? ChatHeader(
                      character: character,
                      sessionName: sessionName,
                      currentSessionIndex: sessionIndex,
                      onTapInfo: () => _showCharacterCard(charId),
                      onTapAvatar:
                          (character.avatarPath != null &&
                              character.avatarPath!.isNotEmpty)
                          ? () => _showAvatarViewer(character.avatarPath!)
                          : null,
                    )
                  : null),
        onBack: () {
          // Dismiss any open overlay first; only navigate up when nothing is
          // open. Order mirrors the precedence the back gesture should follow.
          //
          // Close the drawer BEFORE looking at the input focus. The chat body
          // is an InAppWebView platform view: tapping into it can steal native
          // focus without Flutter clearing `inputFocus`, so `hasFocus` gets
          // stuck `true` with no keyboard on screen. Checking focus first then
          // swallowed the back on a no-op `unfocus()` — the magic drawer /
          // quick replies never closed, and leaving the chat took a second
          // press. Draining the visible overlays first keeps a stale focus flag
          // from eating the gesture.
          if (_drawerCtrl.drawerOpen || _drawerCtrl.switchingToDrawer) {
            _drawerCtrl.closeDrawer();
            return;
          }
          if (_search.showSearch) {
            _search.closeSearch();
            return;
          }
          // Only consume the back to dismiss the keyboard when it is genuinely
          // up. Guarding on the live inset (not just `hasFocus`, which can be
          // stale) means a lingering FocusNode no longer costs an extra press.
          final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
          if (_drawerCtrl.inputFocus.hasFocus && keyboardUp) {
            _drawerCtrl.inputFocus.unfocus();
            return;
          }
          // Nothing left to dismiss — leave the chat. Clear any stale focus so
          // we don't navigate away with the keyboard node still "focused".
          if (_drawerCtrl.inputFocus.hasFocus) {
            _drawerCtrl.inputFocus.unfocus();
          }
          context.go('/');
        },
        actions: _search.showSearch
            ? const []
            : [
                IconButton(
                  icon: const Icon(Icons.search),
                  color: context.cs.primary,
                  onPressed: () {
                    _search.openSearch();
                  },
                ),
              ],
        body: chatStateAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
          data: (state) {
            // The index comparison only gates the INITIAL navigation to a
            // requested session (deep link / history open). Once that initial
            // session has been applied (`_sessionApplied`), in-chat switches
            // like branchSession produce a session with a *different*
            // sessionIndex than `initialSessionIndex` — comparing against it
            // forever would leave the spinner stuck after branching until an
            // app restart. After the initial apply, only `_sessionSwitchPending`
            // gates the spinner.
            final awaitingTargetSession =
                _sessionSwitchPending ||
                (!_sessionApplied &&
                    widget.initialSessionIndex != null &&
                    state.session?.sessionIndex != widget.initialSessionIndex);
            // Only replace the body with a full-screen spinner on the very
            // first open, when the WebView hasn't been built yet. For an
            // in-chat switch (e.g. after importing a chat, which re-navigates
            // to /chat/<id>?session=N) the keep-alive WebView is already
            // mounted; destroying and recreating `_ChatBody` here would not
            // re-run WebView init reliably and left a grey, unresponsive page
            // until restart. Keep the body mounted and overlay the spinner so
            // the WebView's own `_applySessionSwitch` handles the transition.
            if (awaitingTargetSession && !_everBuiltBody) {
              return const Center(child: CircularProgressIndicator());
            }
            _everBuiltBody = true;
            return Stack(
              children: [
                _ChatBody(
                  charId: charId,
                  state: state,
                  drawerCtrl: _drawerCtrl,
                  search: _search,
                  keyboardHeight: keyboardHeight,
                  onScrollDirection: _onScrollDirection,
                  virtualKeyboardSend: virtualKeyboardSend,
                  enterToSend: enterToSend,
                  targetMessageId: widget.targetMessageId,
                  isHeaderHidden: _isHeaderHidden,
                ),
                if (awaitingTargetSession)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Opens the character card (detail sheet) for [charId]. Mirrors
  /// [CharacterDetailSheetLauncher]: the sheet pops a route string when the
  /// user picks an action inside it (edit / gallery / open chat), which we
  /// forward to GoRouter.
  Future<void> _showCharacterCard(String charId) async {
    final navTarget = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CharacterDetailScreen(charId: charId),
    );
    if (!mounted || navTarget == null || navTarget.isEmpty) return;
    context.go(navTarget);
  }

  /// Opens the character avatar in the full-screen image viewer. The avatar is
  /// always an on-disk file, so it resolves straight to a [FileImage] without
  /// the data:/http handling the in-chat image viewer needs.
  void _showAvatarViewer(String avatarPath) {
    final resolved = resolveGlazeFilePath(avatarPath);
    if (resolved == null || resolved.isEmpty) return;
    ImageViewer.show(context, imageProvider: FileImage(File(resolved)));
  }
}

class _ChatBody extends ConsumerStatefulWidget {
  final String charId;
  final ChatState state;
  final ChatDrawerController drawerCtrl;
  final ChatSearchDelegate search;
  final double keyboardHeight;
  final ValueChanged<ScrollDirection>? onScrollDirection;
  final bool virtualKeyboardSend;
  final bool enterToSend;
  final String? targetMessageId;

  /// Mirrors the scaffold's hide-on-scroll header state so the header's
  /// WebView blur region is dropped while the header is slid away.
  final bool isHeaderHidden;

  const _ChatBody({
    required this.charId,
    required this.state,
    required this.drawerCtrl,
    required this.search,
    required this.keyboardHeight,
    this.onScrollDirection,
    this.virtualKeyboardSend = false,
    this.enterToSend = true,
    this.targetMessageId,
    this.isHeaderHidden = false,
  });

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody>
    with WidgetsBindingObserver {
  double _inputBarHeight = 130.0;
  final GlobalKey _inputBarKey = GlobalKey();

  /// Last bottom inset (input bar + keyboard/drawer) pushed to the WebView.
  /// Cached so it can be re-asserted on app resume — see
  /// [didChangeAppLifecycleState].
  double _lastMessageListBottom = 0;

  /// Measured height of the floating [MemoryActivityCard] (0 when hidden) so
  /// the message list reserves room at the *top* for it — otherwise the card
  /// floats under the header and covers the first visible messages.
  double _memoryCardHeight = 0.0;
  final GlobalKey _memoryCardKey = GlobalKey();

  /// Measured height of the box the chat WebView is laid out in. Pushed to the
  /// page alongside the bottom inset: whether the soft keyboard shrinks the
  /// WebView's own viewport or merely overlays it is decided by the embedder
  /// (Android window resize mode, iOS WKWebView, desktop) and Flutter cannot
  /// tell which happened, so the page compares this against its live viewport
  /// height and turns only the *unabsorbed* part of the inset into padding.
  /// Measuring the real box (rather than assuming the screen height) keeps that
  /// comparison honest on desktop, where the chat is not full-screen.
  double _webViewBoxHeight = 0.0;
  final GlobalKey _webViewBoxKey = GlobalKey();

  final _selectionCtrl = ChatMessageSelectionController();
  bool _showScrollToBottom = false;
  bool _showMemoryActivity = false;
  final GlobalKey<ChatWebViewWidgetState> _webViewStateKey = GlobalKey();

  /// Rects of the glass overlays (header + input bar elements) measured in
  /// WebView-local coordinates and mirrored into the WebView so the messages
  /// scrolling underneath get blurred (Flutter's BackdropFilter cannot
  /// sample the platform view — see [ChatOverlayBlurRegion]).
  final ChatBlurRegionRegistry _blurRegistry = ChatBlurRegionRegistry();
  List<ChatOverlayBlurRegion> _blurRegions = const [];
  bool _blurMeasureScheduled = false;

  /// `MediaQuery.padding.top` captured in build for the analytic header rect.
  double _blurSafeTop = 0;

  /// Keyboard-inset settle tracking for the WebView-bound bottom inset.
  /// While the keyboard animates, the WebView receives the predicted end
  /// value once (per-frame `setBottomPadding` pushes relayout the whole
  /// message list in the WebView every frame — the main keyboard-jank
  /// source). [_keyboardSettled] flips back once the inset stops changing
  /// and the actual value is pushed as a correction — a no-op in JS when
  /// the prediction was right.
  bool _keyboardSettled = true;
  bool _keyboardRising = false;
  Timer? _keyboardSettleTimer;

  /// Drives the bottom-panel subtree. The drawer animation alone is not
  /// enough: switching between Quick Access and Quick Replies while the
  /// drawer is already open leaves the animation parked at 1.0 and only
  /// flips [ChatDrawerController.activePanel], so without listening to the
  /// controller itself the tapped panel never rebuilds into view.
  late Listenable _drawerListenable;

  void _bindDrawerListenable() {
    _drawerListenable = Listenable.merge([
      widget.drawerCtrl.drawerAnim,
      widget.drawerCtrl,
    ]);
  }

  @override
  void didUpdateWidget(covariant _ChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drawerCtrl != widget.drawerCtrl) {
      _bindDrawerListenable();
    }
    if (oldWidget.keyboardHeight != widget.keyboardHeight) {
      _keyboardRising = widget.keyboardHeight > oldWidget.keyboardHeight;
      _keyboardSettled = false;
      _keyboardSettleTimer?.cancel();
      _keyboardSettleTimer = Timer(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        setState(() => _keyboardSettled = true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindDrawerListenable();
    // Re-measure when the input bar swaps tracked elements (e.g. entering
    // search/selection mode) without this widget rebuilding.
    _blurRegistry.addListener(_scheduleBlurMeasure);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkHeight());
    final targetId = widget.targetMessageId;
    if (targetId != null && targetId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_scrollToTargetMessage(targetId)),
      );
    }
  }

  /// Waits for the keep-alive WebView to finish initializing, then scrolls to
  /// and flashes the message that a tapped notification points at. Mirrors
  /// Vue's openChat(msgId) → scrollToAnchor + search-highlight behaviour.
  Future<void> _scrollToTargetMessage(String messageId) async {
    for (var i = 0; i < 100; i++) {
      if (!mounted) return;
      final st = _webViewStateKey.currentState;
      if (st != null && st.isReady) {
        // Let the initializer's opening scroll-to-bottom settle before
        // retargeting, otherwise the two scrolls fight each other.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
        await st.scrollToMessage(messageId, highlight: true);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _checkHeight() {
    if (!mounted) return;
    var changed = false;
    var nextInputBarHeight = _inputBarHeight;
    var nextMemoryCardHeight = _memoryCardHeight;
    var nextWebViewBoxHeight = _webViewBoxHeight;

    final inputCtx = _inputBarKey.currentContext;
    if (inputCtx != null) {
      final size = inputCtx.size;
      if (size != null && size.height != _inputBarHeight && size.height > 0) {
        nextInputBarHeight = size.height;
        changed = true;
      }
    }

    // The memory card is only mounted while visible. When it is absent its
    // reserved top height collapses back to 0 so the list reclaims the space.
    final memoryHeight = _memoryCardKey.currentContext?.size?.height ?? 0.0;
    if (memoryHeight != _memoryCardHeight) {
      nextMemoryCardHeight = memoryHeight;
      changed = true;
    }

    // Only ever grows/shrinks with the window itself (rotation, desktop resize)
    // — the keyboard cannot move it, since the scaffold runs with
    // `resizeToAvoidBottomInset: false`.
    final boxHeight = _webViewBoxKey.currentContext?.size?.height ?? 0.0;
    if (boxHeight > 0 && boxHeight != _webViewBoxHeight) {
      nextWebViewBoxHeight = boxHeight;
      changed = true;
    }

    if (changed) {
      setState(() {
        _inputBarHeight = nextInputBarHeight;
        _memoryCardHeight = nextMemoryCardHeight;
        _webViewBoxHeight = nextWebViewBoxHeight;
      });
    }
  }

  Future<void> _scrollToBottom() async {
    final webViewState = _webViewStateKey.currentState;
    if (webViewState != null) {
      // Mirror Vue: the scroll-to-bottom button animates smoothly (the JS side
      // falls back to an instant jump when more than 3000px away).
      await webViewState.scrollToBottom(smooth: true);
    }
    if (!mounted) return;
    setState(() => _showScrollToBottom = false);
  }

  void _showImageViewer(BuildContext context, String imageUrl) {
    final provider = imageProviderForSrc(imageUrl);
    if (provider == null) {
      GlazeToast.show(
        context,
        'image_viewer_unsupported_src'.tr(),
        isError: true,
      );
      return;
    }
    ImageViewer.show(context, imageProvider: provider);
  }

  /// Saves/shares a generated image. The native share sheet on iOS/Android
  /// exposes "Save Image"/"Save to Photos", which is the supported way to get
  /// the image into the gallery without a dedicated gallery-saver dependency.
  Future<void> _downloadImage(String src) async {
    try {
      Uint8List bytes;
      String ext = 'png';
      // A loopback `__glaze_file__` URL is a local file wearing an http coat —
      // read it off disk instead of round-tripping through the WebView server.
      final loopbackPath = glazeFilePathFromLoopbackUrl(src);
      final localSrc = loopbackPath ?? src;
      if (src.startsWith('data:')) {
        final commaIdx = src.indexOf(',');
        if (commaIdx == -1) return;
        bytes = base64Decode(src.substring(commaIdx + 1));
        final header = src.substring(0, commaIdx).toLowerCase();
        if (header.contains('jpeg') || header.contains('jpg')) ext = 'jpg';
      } else if (loopbackPath == null &&
          (src.startsWith('http://') || src.startsWith('https://'))) {
        final resp = await Dio().get<List<int>>(
          src,
          options: Options(responseType: ResponseType.bytes),
        );
        bytes = Uint8List.fromList(resp.data ?? const []);
        if (src.toLowerCase().contains('.jpg') ||
            src.toLowerCase().contains('.jpeg')) {
          ext = 'jpg';
        }
      } else {
        final path = imageSrcToFilePath(localSrc);
        final resolved = resolveGlazeFilePath(path) ?? path;
        final file = File(resolved);
        if (!await file.exists()) return;
        bytes = await file.readAsBytes();
        final lower = resolved.toLowerCase();
        if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) ext = 'jpg';
      }
      if (bytes.isEmpty) return;

      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(
        p.join(
          tmpDir.path,
          'glaze_image_${DateTime.now().millisecondsSinceEpoch}.$ext',
        ),
      );
      await tmpFile.writeAsBytes(bytes);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tmpFile.path)],
          // Required on iPad so the share popover has an anchor rect.
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        ),
      );
    } catch (e) {
      if (mounted) {
        GlazeErrorDialog.show(context, e, prefix: 'settings_err_failed'.tr());
      }
    }
  }

  void _showTriggeredItemsSheet(
    BuildContext context, {
    List<TriggeredEntry> lorebooks = const [],
    List<TriggeredEntry> memories = const [],
    List<TriggeredEntry> regexes = const [],
  }) {
    showTriggeredItemsSheet(
      context,
      lorebooks: lorebooks,
      memories: memories,
      regexes: regexes,
    );
  }

  /// Options sheet for a generated/janitor image (Imagen UI, ported from
  /// Glaze useMessageImageGen.js): Expand → fullscreen, Save → share/save,
  /// Regenerate → re-run image generation for the owning message. The
  /// Regenerate entry is hidden when the owning message can't be resolved in
  /// the current list (no messageId, or the message is already gone).
  ///
  /// Uses [GlazeBottomSheet] so the sheet matches every other action sheet in
  /// the app (glass surface, handle bar, haptics) instead of a bare Material
  /// `showModalBottomSheet`.
  void _showImageOptionsSheet(
    String src,
    String instruction,
    String messageId,
  ) {
    final messages = widget.state.messages;
    final idx = messageId.isEmpty
        ? -1
        : messages.indexWhere((m) => m.id == messageId);

    GlazeBottomSheet.show<void>(
      context,
      items: [
        BottomSheetItem(
          icon: Icons.fullscreen,
          label: 'imggen_expand_image'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showImageViewer(context, src);
          },
        ),
        BottomSheetItem(
          icon: Icons.save_alt,
          label: 'action_save_image'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _downloadImage(src);
          },
        ),
        if (idx >= 0)
          BottomSheetItem(
            icon: Icons.refresh,
            label: 'action_regenerate'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(chatProvider(widget.charId).notifier)
                  .retryImageGenerationForMessage(messageId);
            },
          ),
      ],
    );
  }

  /// Guards message sending behind an explicitly selected persona. When no
  /// persona is selected in the persona list, shows a notice sheet with a
  /// shortcut to pick one and returns false so the caller aborts the send.
  bool _ensurePersonaSelected() {
    if (ref.read(activePersonaIdProvider) != null) return true;
    GlazeBottomSheet.show<void>(
      context,
      title: 'persona_required_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.person_off_outlined,
        description: 'persona_required_desc'.tr(),
        buttonText: 'persona_required_select'.tr(),
        onButtonTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const PersonaListScreen(),
          );
        },
      ),
    );
    return false;
  }

  /// Guards message sending behind a configured API. When no API config is
  /// available, shows a notice sheet with a shortcut to the API settings and
  /// returns false so the caller aborts the send.
  bool _ensureApiSelected() {
    if (ref.read(activeApiConfigProvider) != null) return true;
    GlazeBottomSheet.show<void>(
      context,
      title: 'api_required_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.cloud_off_outlined,
        description: 'api_required_desc'.tr(),
        buttonText: 'api_required_select'.tr(),
        onButtonTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            barrierColor: Colors.black54,
            builder: (_) => const ApiSettingsScreen(),
          );
        },
      ),
    );
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keyboardSettleTimer?.cancel();
    _blurRegistry.dispose();
    super.dispose();
  }

  /// Coalesces measurement requests into one post-frame pass. Scheduled on
  /// every build (keyboard/drawer animations move the input bar each frame)
  /// and on registry changes.
  void _scheduleBlurMeasure() {
    if (_blurMeasureScheduled) return;
    _blurMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _blurMeasureScheduled = false;
      _measureBlurRegions();
    });
  }

  void _measureBlurRegions() {
    if (!mounted) return;
    // Transient layout: while the keyboard or drawer animates, the overlays
    // move every frame — re-measuring would push per-frame region updates
    // over the JS bridge and repaint the Flutter blur sandwich each frame.
    // A build is guaranteed at settle (the keyboard settle-timer setState,
    // the drawer animation's final tick with isAnimating == false), and it
    // re-schedules this measure, so the final rects always land.
    if (!_keyboardSettled || widget.drawerCtrl.isDrawerAnimating) return;
    final box = _webViewStateKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final regions = <ChatOverlayBlurRegion>[
      // The floating header is not a descendant (it lives in GlazeScaffold's
      // stack), but its geometry is fixed: SafeArea + fromLTRB(16, 10, 16, 0)
      // + 56px GlazeAppBar with radius 20 (glaze_scaffold.dart).
      if (!widget.isHeaderHidden)
        ChatOverlayBlurRegion(
          id: 'header',
          rect: Rect.fromLTWH(
            16 - origin.dx,
            _blurSafeTop + 10 - origin.dy,
            box.size.width - 32,
            56,
          ),
          radius: 20,
        ),
      ..._blurRegistry.measure(box),
    ];
    regions.sort((a, b) => a.id.compareTo(b.id));
    if (!listEquals(regions, _blurRegions)) {
      setState(() => _blurRegions = regions);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The native WebView freezes its JS while the app is backgrounded, so a
    // bottom-inset change pushed during the background transition (e.g. the
    // keyboard hiding) can be dropped. If the app then resumes with the
    // keyboard re-opening at the same height, Dart's bottomInset is unchanged
    // so the per-frame diff in the sync dispatcher never re-pushes it — leaving
    // stale, oversized reserved space under the input bar. Re-assert the
    // current inset once now and again after the keyboard settles; the JS side
    // no-ops when the padding already matches.
    void resync() {
      if (!mounted) return;
      unawaited(
        _webViewStateKey.currentState?.applyBottomInset(
              _lastMessageListBottom,
              viewportHeight: _webViewBoxHeight,
            ) ??
            Future<void>.value(),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => resync());
    Future<void>.delayed(const Duration(milliseconds: 400), resync);
  }

  @override
  Widget build(BuildContext context) {
    final isEditingMessage =
        ref.watch(editingMessageIdProvider(widget.charId)) != null;
    final memoryActivity = ref.watch(lastMemoryActivityProvider(widget.charId));
    final memoryEnabled = ref.watch(
      memoryGlobalSettingsProvider.select((s) => s.enabled),
    );
    ref.listen<String?>(editingMessageIdProvider(widget.charId), (prev, next) {
      if (next != null) {
        if (widget.drawerCtrl.inputFocus.hasFocus) {
          widget.drawerCtrl.inputFocus.unfocus();
        }
        if (_selectionCtrl.isSelectionMode ||
            _selectionCtrl.selectedMessageIds.isNotEmpty) {
          setState(() {
            _selectionCtrl.clearSelection();
          });
        }
      }
    });
    ref.listen<bool>(impersonationNeedsConfigProvider(widget.charId), (
      prev,
      next,
    ) {
      if (next) {
        ref
                .read(impersonationNeedsConfigProvider(widget.charId).notifier)
                .state =
            false;
        if (!context.mounted) return;
        GlazeBottomSheet.show<void>(
          context,
          bigInfo: BottomSheetBigInfo(
            icon: Icons.record_voice_over_outlined,
            description: 'impersonation_prompt_missing'.tr(),
            buttonText: 'btn_configure'.tr(),
            onButtonTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              final preset = ref.read(
                effectivePresetForChatProvider((
                  charId: widget.charId,
                  sessionId: widget.state.session?.id,
                )),
              );
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PresetEditorScreen(
                    preset: preset,
                    charId: widget.charId,
                  ),
                ),
              );
            },
          ),
        );
      }
    });
    final appSettings = ref.watch(appSettingsProvider).value;
    final batterySaverMode = appSettings?.batterySaver ?? false;
    final preset = batteryAware(
      ref,
      batterySaverMode,
      themeProvider.select((p) => p.activePreset),
    );
    final batterySaver = appSettings?.batterySaver ?? false;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final messageListTop = MediaQuery.paddingOf(context).top + 10 + 56;
    _blurSafeTop = MediaQuery.paddingOf(context).top;

    final bgBlur = preset.bgBlur > 0 ? preset.bgBlur : 0.0;
    final bgOpacity = preset.bgOpacity.clamp(0.0, 1.0);
    final fontStyle = batteryAware(
      ref,
      batterySaverMode,
      chatFontStyleProvider,
    );
    final fontDataUrl = batteryAware(
      ref,
      batterySaverMode,
      chatFontDataProvider.select((p) => p.value),
    );
    final character = batteryAware(
      ref,
      batterySaverMode,
      characterByIdProvider(widget.charId),
    );
    // Source for the in-WebView background copy, mirroring what the Flutter
    // ChatWebViewSurface._background() paints for each chatBgMode so the
    // duplicated background matches. 'color' has no image.
    final bgPath = switch (preset.chatBgMode) {
      'custom' => preset.chatBgImage,
      'avatar' => character?.avatarPath,
      'color' => null,
      _ => preset.bgImage, // 'inherit'
    };
    final personaKey = (
      charId: widget.charId,
      sessionId: widget.state.session?.id,
    );
    final effectivePersona = batteryAware(
      ref,
      batterySaverMode,
      effectivePersonaForChatProvider(personaKey),
    );
    ref.listen(effectivePersonaForChatProvider(personaKey), (prev, next) {
      if (prev?.id == next?.id &&
          prev?.name == next?.name &&
          prev?.avatarPath == next?.avatarPath) {
        return;
      }
      _webViewStateKey.currentState?.applyIdentity(
        charName: character?.name,
        charColor: character?.color,
        personaName: next?.name,
        charAvatarPath: character?.avatarPath,
        personaAvatarPath: next?.avatarPath,
        greetingTotal: character == null
            ? 0
            : ((character.firstMes?.isNotEmpty == true ? 1 : 0) +
                  character.alternateGreetings
                      .where((g) => g.isNotEmpty)
                      .length),
      );
    });
    final memBook = batteryAware(
      ref,
      batterySaverMode,
      memoryBookProvider(widget.state.session?.id ?? ''),
    );
    final greetingTotal = character == null
        ? 0
        : ((character.firstMes?.isNotEmpty == true ? 1 : 0) +
              character.alternateGreetings.where((g) => g.isNotEmpty).length);

    return AnimatedBuilder(
      animation: _drawerListenable,
      builder: (context, _) {
        final progress = widget.drawerCtrl.drawerAnim.value;
        final bool drawerActive =
            widget.drawerCtrl.drawerOpen || widget.drawerCtrl.switchingToDrawer;
        final targetDrawerInset = drawerActive
            ? widget.drawerCtrl.activeDrawerHeight * progress
            : 0.0;
        final panelHeight = math.max(targetDrawerInset, widget.keyboardHeight);
        final factor = math.min(1.0, panelHeight / math.max(1.0, safeBottom));
        final effectiveBottomInset = panelHeight + (safeBottom * (1 - factor));
        // The memory activity card floats under the header (top of the chat).
        // Hidden entirely when memory books are disabled globally.
        final showMemoryCard =
            memoryActivity != null &&
            memoryActivity.hasDiagnostics &&
            memoryEnabled;
        // When the card is dismissed its widget unmounts, so the size notifier
        // can't fire — reclaim the reserved top space on the next frame.
        if (!showMemoryCard && _memoryCardHeight != 0.0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _checkHeight());
        }
        // Reserve room at the top so the card sits in a gap under the header
        // instead of covering the first visible messages.
        final memoryTopReserve = showMemoryCard ? _memoryCardHeight + 8 : 0.0;
        final effectiveTopInset = messageListTop + memoryTopReserve;

        final messageListBottom = _inputBarHeight + effectiveBottomInset;

        // WebView-bound inset: the *end value* of the current transition,
        // not the per-frame animated one. Pushing the animated value would
        // relayout the whole in-WebView message list on every keyboard/
        // drawer frame (see setBottomPadding in chat_bridge_controller.js).
        // The Flutter overlays below keep following the animation; only the
        // WebView padding jumps once, then gets corrected on settle (see
        // didUpdateWidget). While the keyboard rises, the end value is
        // predicted from the persisted last keyboard height; while it
        // lowers, the end value is 0 (or the drawer height when switching).
        final drawerTargetInset = drawerActive
            ? widget.drawerCtrl.activeDrawerHeight
            : 0.0;
        final keyboardTargetInset = _keyboardSettled
            ? widget.keyboardHeight
            : (_keyboardRising
                  ? math.max(
                      widget.keyboardHeight,
                      widget.drawerCtrl.lastKeyboardHeight,
                    )
                  : 0.0);
        final targetPanelHeight = math.max(
          drawerTargetInset,
          keyboardTargetInset,
        );
        final targetFactor = math.min(
          1.0,
          targetPanelHeight / math.max(1.0, safeBottom),
        );
        // While inline-editing a message, reserve extra scroll room at the
        // bottom. The normal inset only matches the input bar + keyboard, so a
        // message edited at the very end of the chat can scroll its body up to
        // that boundary but no further — and in bubble mode the Save/Cancel
        // footer wraps onto its own row *below* the bubble, landing behind the
        // input bar where it can't be reached. The extra padding lets the whole
        // edit footer clear the bottom overlays. Reclaimed automatically when
        // editing ends (isEditingMessage flips back to false).
        const editFooterScrollRoom = 96.0;
        final webViewBottomInset =
            _inputBarHeight +
            targetPanelHeight +
            (safeBottom * (1 - targetFactor)) +
            (isEditingMessage ? editFooterScrollRoom : 0.0);
        _lastMessageListBottom = webViewBottomInset;
        final showScrollBtn =
            _showScrollToBottom &&
            !widget.search.showSearch &&
            !isEditingMessage;

        final animatedBottomPanelInset =
            panelHeight + (safeBottom * (1 - factor));
        final renderDrawer =
            !isDesktopLayout(context) &&
            (widget.drawerCtrl.drawerOpen || progress > 0.001);

        // The overlays move with every rebuild here (keyboard, drawer
        // animation, input growth), so re-measure their rects post-frame.
        _scheduleBlurMeasure();

        // The box height feeds the WebView's inset split (see
        // [_webViewBoxHeight]). It is normally captured by the post-frame
        // measure in initState, but if that frame lands before this subtree is
        // laid out the height stays 0 — and SizeChangedLayoutNotifier only
        // fires on *changes*, never on a first layout, so nothing would ever
        // re-measure it and the split would stay silently disabled. Keep
        // asking until it lands.
        if (_webViewBoxHeight == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _checkHeight());
        }

        return Stack(
          children: [
            // The box height feeds the WebView's inset split (see
            // [_webViewBoxHeight]); re-measure whenever it changes (rotation,
            // desktop window resize). The keyboard never triggers this — the
            // scaffold keeps the body full-size while it is up.
            Positioned.fill(
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (n) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _checkHeight(),
                  );
                  return true;
                },
                child: SizeChangedLayoutNotifier(
                  key: _webViewBoxKey,
                  child: NotificationListener<UserScrollNotification>(
                    onNotification: (notification) {
                      // Do NOT drive the header from Flutter scroll notifications.
                      // The chat list is an InAppWebView platform view whose internal
                      // scroll never bubbles here — the only notifications this can
                      // catch are from stray Flutter scrollables inside the subtree
                      // (panels, overlays, dropdowns). Forwarding those flipped
                      // `_isHeaderHidden` out of band while JS still believed the
                      // opposite, and since JS only emits header events on
                      // transitions (edge-triggered) it never corrected the desync,
                      // leaving the header frozen. JS `onHeaderScroll` is the single
                      // source of truth (see ScrollCallbacks.onHeaderScroll below).
                      return false;
                    },
                    child: RepaintBoundary(
                      child: ChatWebViewWidget(
                        key: _webViewStateKey,
                        messages: widget.state.visibleMessages,
                        charId: widget.charId,
                        isGenerating: widget.state.isGenerating,
                        isGeneratingImage: widget.state.isGeneratingImage,
                        isPostGenRunning: widget.state.isPostGenRunning,
                        regenTargetId: widget.state.regenTargetId,
                        continuationTargetId:
                            widget.state.continuationTargetId,
                        bottomInset: webViewBottomInset,
                        viewportHeight: _webViewBoxHeight,
                        topInset: effectiveTopInset,
                        blurRegions: (batterySaver || preset.elementBlur <= 0)
                            ? const <ChatOverlayBlurRegion>[]
                            : _blurRegions,
                        charName: character?.name,
                        charColor: character?.color,
                        personaName: effectivePersona?.name,
                        greetingTotal: greetingTotal,
                        chatLayout: preset.chatLayout,
                        themeSyncKey: _chatWebViewThemeSyncKey(
                          preset,
                          preset.chatLayout,
                        ),
                        elementOpacity: preset.elementOpacity,
                        elementBlur: preset.elementBlur,
                        uiFontWeight: preset.uiFontWeight,
                        userMessageFontWeight: preset.userMessageFontWeight,
                        charMessageFontWeight: preset.charMessageFontWeight,
                        userBubbleRadius: preset.userBubbleRadius,
                        charBubbleRadius: preset.charBubbleRadius,
                        userBubbleGradient: preset.userBubbleGradientParsed,
                        charBubbleGradient: preset.charBubbleGradientParsed,
                        textBgOpacity: preset.textBgOpacity,
                        showUserAvatar: preset.showUserAvatar,
                        showCharAvatar: preset.showCharAvatar,
                        showUserName: preset.showUserName,
                        showCharName: preset.showCharName,
                        charAvatarPath: character?.avatarPath,
                        personaAvatarPath: effectivePersona?.avatarPath,
                        bgImagePath: bgPath,
                        bgBlur: bgBlur,
                        bgOpacity: bgOpacity,
                        bgNoiseOpacity: preset.bgNoiseOpacity,
                        bgNoiseIntensity: preset.bgNoiseIntensity,
                        bgDim: preset.bgDim,
                        chatBgMode: preset.chatBgMode,
                        chatBgColor: preset.chatBgColorParsed,
                        chatFontName: fontStyle.fontFamily,
                        chatFontDataUrl: fontDataUrl,
                        chatFontSize: fontStyle.fontSize,
                        chatLetterSpacing: fontStyle.letterSpacing,
                        memoryEntries: memBook.value?.entries ?? [],
                        memoryDrafts: memBook.value?.pendingDrafts ?? [],
                        sessionId: widget.state.session?.id,
                        visibleStartIndex: widget.state.visibleStartIndex,
                        batterySaver: appSettings?.batterySaver ?? false,
                        hideMessageId:
                            preset.hideMessageId ??
                            (appSettings?.hideMessageId ?? false),
                        hideGenerationTime:
                            preset.hideGenerationTime ??
                            (appSettings?.hideGenerationTime ?? false),
                        hideTokenCount:
                            preset.hideTokenCount ??
                            (appSettings?.hideTokenCount ?? false),
                        disableSwipeRegeneration:
                            appSettings?.disableSwipeRegeneration ?? false,
                        studioEnabled:
                            ref
                                .watch(
                                  sessionStudioEnabledProvider(
                                    widget.state.session?.id ?? '',
                                  ),
                                )
                                .value ??
                            false,
                        messageActions: MessageActionsCallbacks(
                          onMessageContext:
                              (index, messageId, isUser, isSystem, content) {
                                showMessageContextMenu(
                                  context: context,
                                  ref: ref,
                                  charId: widget.charId,
                                  content: content,
                                  messageIndex: index,
                                  messageId: messageId,
                                  isUser: isUser,
                                  isTyping:
                                      widget.state.isGenerating &&
                                      index == widget.state.messages.length - 1,
                                  isError: false,
                                  isLast:
                                      index ==
                                      widget.state.messages.length - 1,
                                  isGenerating: widget.state.isGenerating,
                                  isHidden:
                                      widget.state.messages[index].isHidden,
                                  canDeleteSwipe:
                                      !isUser &&
                                      widget
                                              .state
                                              .messages[index]
                                              .swipes
                                              .length >
                                          1,
                                  canDeleteAgentSwipe:
                                      !isUser &&
                                      widget
                                              .state
                                              .messages[index]
                                              .agentSwipes
                                              .length >
                                          1,
                                );
                              },
                          onSwipe: (id, direction) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx < 0) return;
                            final dir = direction == 'right' ? 1 : -1;
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .changeSwipe(idx, dir, fromSwipe: true);
                          },
                          onAgentSwipe: (id, direction) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx < 0) return;
                            final dir = direction == 'right' ? 1 : -1;
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .changeAgentSwipe(idx, dir, fromSwipe: true);
                          },
                          onChangeGreeting: (id, dir) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx < 0) return;
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .setGreeting(idx, dir);
                          },
                          onRegenerate: (id, mode) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .regenerateLastAssistant();
                          },
                          onRerunCleaner: (id) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .rerunCleaner(id);
                          },
                          onToggleHidden: (id) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx >= 0) {
                              ref
                                  .read(chatProvider(widget.charId).notifier)
                                  .toggleMessageHidden(idx);
                            }
                          },
                          onToggleImageHidden: (id) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx >= 0) {
                              ref
                                  .read(chatProvider(widget.charId).notifier)
                                  .toggleImageHidden(idx);
                            }
                          },
                          onMemoryClick: (id) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx < 0) return;
                            final msg = widget.state.messages[idx];
                            if (msg.triggeredMemories.isNotEmpty) {
                              _showTriggeredItemsSheet(
                                context,
                                memories: msg.triggeredMemories,
                              );
                            }
                          },
                          onGuidedSwipe: (id, guidanceText) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx < 0) return;
                            final msg = widget.state.messages[idx];
                            final isLastAssistant =
                                msg.role == 'assistant' &&
                                idx == widget.state.messages.length - 1;
                            if (isLastAssistant) {
                              ref
                                  .read(chatProvider(widget.charId).notifier)
                                  .regenerateLastAssistant(
                                    guidanceText: guidanceText,
                                  );
                            }
                          },
                          onInjectClick: (id) {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx < 0) return;
                            final msg = widget.state.messages[idx];
                            _showTriggeredItemsSheet(
                              context,
                              lorebooks: msg.triggeredLorebooks,
                              memories: msg.triggeredMemories,
                              regexes:
                                  _webViewStateKey.currentState
                                      ?.triggeredRegexesFor(id) ??
                                  const [],
                            );
                          },
                        ),
                        editActions: EditActionsCallbacks(
                          onEditSave: (id, text) async {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx >= 0 && text.isNotEmpty) {
                              await ref
                                  .read(chatProvider(widget.charId).notifier)
                                  .editMessage(
                                    idx,
                                    text,
                                    tagStart: '<think>',
                                    tagEnd: '</think>',
                                  );
                            }
                            if (!mounted ||
                                ref.read(
                                      editingMessageIdProvider(widget.charId),
                                    ) !=
                                    id) {
                              return;
                            }
                            ref
                                    .read(
                                      editingMessageIdProvider(
                                        widget.charId,
                                      ).notifier,
                                    )
                                    .state =
                                null;
                          },
                          onEditCancel: (id) {
                            ref
                                    .read(
                                      editingMessageIdProvider(
                                        widget.charId,
                                      ).notifier,
                                    )
                                    .state =
                                null;
                          },
                          onEditFocusChange: (id, focused) {
                            if (!focused) return;
                            final activeEditingId = ref.read(
                              editingMessageIdProvider(widget.charId),
                            );
                            if (activeEditingId == id &&
                                widget.drawerCtrl.inputFocus.hasFocus) {
                              widget.drawerCtrl.inputFocus.unfocus();
                            }
                          },
                        ),
                        imageGenActions: ImageGenCallbacks(
                          onImgRetry: (instruction, messageId) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .retryImageGenerationForMessage(messageId);
                          },
                          onImgFind: (instruction, messageId) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .findImageOnDisk(messageId, instruction);
                          },
                          onImgRegen: (instruction, messageId) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .retryImageGenerationForMessage(messageId);
                          },
                          onImgCancel: () {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .cancelImageGeneration();
                          },
                          onImgDownload: _downloadImage,
                          onImgOptions: _showImageOptionsSheet,
                        ),
                        scrollActions: ScrollCallbacks(
                          onHeaderScroll: (hidden) {
                            if (widget.onScrollDirection == null) return;
                            widget.onScrollDirection!(
                              hidden
                                  ? ScrollDirection.reverse
                                  : ScrollDirection.forward,
                            );
                          },
                          onScrollToBottomVisibility: (visible) {
                            if (!mounted || _showScrollToBottom == visible) {
                              return;
                            }
                            setState(() => _showScrollToBottom = visible);
                          },
                        ),
                        miscActions: MiscCallbacks(
                          onStop: () {
                            final notifier = ref.read(
                              chatProvider(widget.charId).notifier,
                            );
                            if (widget.state.isGeneratingImage &&
                                !widget.state.isGenerating) {
                              notifier.cancelImageGeneration();
                            } else {
                              notifier.abortGeneration();
                            }
                          },
                          onSelectionAction: (action, text) {
                            if (action == 'copy') {
                              Clipboard.setData(ClipboardData(text: text));
                            }
                          },
                          onSelectionChange: (ids) {
                            if (mounted) {
                              setState(() {
                                _selectionCtrl.updateSelection(ids);
                              });
                            }
                          },
                          onImageClick: (imageUrl) {
                            _showImageViewer(context, imageUrl);
                          },
                        ),
                        isSelectionMode: _selectionCtrl.isSelectionMode,
                        searchQuery: widget.search.searchQuery,
                        searchCurrentIndex: widget.search.searchCurrentIndex,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Top gradient for fade effect under the header
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.paddingOf(context).top + 20,
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
            // Bottom gradient for fade effect under the input area
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: messageListBottom + 40,
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                      stops: [0.0, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: messageListBottom + 16,
              child: IgnorePointer(
                // Mirror Vue ChatInput (`v-if="!isSearchMode"`): the
                // scroll-to-bottom button is suppressed while searching.
                ignoring: !showScrollBtn,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  opacity: showScrollBtn ? 1 : 0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    offset: showScrollBtn ? Offset.zero : const Offset(0, 0.2),
                    child: GestureDetector(
                      onTap: _scrollToBottom,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: context.cs.surface.withValues(alpha: 0.9),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.22),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: context.cs.primary,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Memory activity card: floats under the header, over the chat.
            if (showMemoryCard)
              Positioned(
                top: messageListTop,
                left: 12,
                right: 12,
                child: NotificationListener<SizeChangedLayoutNotification>(
                  onNotification: (n) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _checkHeight(),
                    );
                    return true;
                  },
                  child: SizeChangedLayoutNotifier(
                    child: Container(
                      key: _memoryCardKey,
                      child: MemoryActivityCard(
                        activity: memoryActivity,
                        expanded: _showMemoryActivity,
                        sessionId: widget.state.session?.id,
                        onToggle: () {
                          setState(() {
                            _showMemoryActivity = !_showMemoryActivity;
                          });
                        },
                      ),
                    ),
                  ),
                ),
              ),
            // POST-cleaner live status card. Rendered AFTER the memory activity
            // card so it sits ABOVE it in z-order — the Stop button must stay
            // clickable even when the memory card is visible underneath.
            Positioned(
              left: 12,
              right: 12,
              top: messageListTop + memoryTopReserve,
              child: const PostCleanerStatusCard(),
            ),
            // Studio tracker-cycle live status card. Shown during generation
            // while Studio trackers / final generator are running.
            Positioned(
              left: 12,
              right: 12,
              top: messageListTop + memoryTopReserve + 56,
              child: const StudioStatusCard(),
            ),
            // Post-generation tasks (Ledger and extension blocks) live status.
            Positioned(
              left: 12,
              right: 12,
              top: messageListTop + memoryTopReserve + 112,
              child: PostGenStatusCard(sessionId: widget.state.session?.id),
            ),
            // Bottom panel: drawer + input bar
            Positioned.fill(
              child: Stack(
                children: [
                  if (renderDrawer)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom:
                          -widget.drawerCtrl.activeDrawerHeight *
                          (1 - progress),
                      height: widget.drawerCtrl.activeDrawerHeight,
                      child:
                          widget.drawerCtrl.activePanel ==
                              DrawerPanel.quickReplies
                          ? QuickRepliesPanel(
                              charId: widget.charId,
                              onClose: () => widget.drawerCtrl.closeDrawer(),
                              disableEffects:
                                  batterySaver &&
                                  widget.drawerCtrl.isDrawerAnimating,
                            )
                          : MagicDrawerPanel(
                              charId: widget.charId,
                              onClose: () => widget.drawerCtrl.closeDrawer(),
                              disableEffects:
                                  batterySaver &&
                                  widget.drawerCtrl.isDrawerAnimating,
                              onScrollToMessage: (id) =>
                                  _scrollToTargetMessage(id),
                            ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: animatedBottomPanelInset,
                    child: ChatBlurRegionScope(
                      registry: _blurRegistry,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NotificationListener<SizeChangedLayoutNotification>(
                            onNotification: (n) {
                              WidgetsBinding.instance.addPostFrameCallback(
                                (_) => _checkHeight(),
                              );
                              return true;
                            },
                            child: SizeChangedLayoutNotifier(
                              child: Container(
                                key: _inputBarKey,
                                child: Builder(
                                  builder: (context) {
                                    final allSelectedHidden = _selectionCtrl
                                        .allSelectedHidden(
                                          widget.state.messages,
                                        );
                                    return ChatInputBar(
                                      focusNode: widget.drawerCtrl.inputFocus,
                                      initialDraft:
                                          widget.state.session?.draft ?? '',
                                      batterySaver:
                                          appSettings?.batterySaver ?? false,
                                      onDraftChanged: (text) {
                                        ref
                                            .read(
                                              chatProvider(
                                                widget.charId,
                                              ).notifier,
                                            )
                                            .saveDraft(text);
                                      },
                                      showSearchControls:
                                          widget.search.showSearch,
                                      searchQuery: widget.search.searchQuery,
                                      searchMatchCount:
                                          widget.search.matchCount,
                                      searchCurrentIndex:
                                          widget.search.searchCurrentIndex,
                                      onSearchNext: widget.search.onSearchNext,
                                      onSearchPrev: widget.search.onSearchPrev,
                                      isEditingMessage: isEditingMessage,
                                      isSelectionMode:
                                          _selectionCtrl.isSelectionMode,
                                      selectedCount: _selectionCtrl
                                          .selectedMessageIds
                                          .length,
                                      allSelectedHidden: allSelectedHidden,
                                      onCancelSelection: () {
                                        setState(() {
                                          _selectionCtrl.clearSelection();
                                        });
                                      },
                                      onHideSelected: () async {
                                        await _selectionCtrl.hideSelected(
                                          ref,
                                          widget.charId,
                                          widget.state.messages,
                                        );
                                        if (mounted) setState(() {});
                                      },
                                      onDeleteSelected: () async {
                                        await _selectionCtrl.deleteSelected(
                                          ref,
                                          widget.charId,
                                          widget.state.messages,
                                        );
                                        if (mounted) setState(() {});
                                      },
                                      isDrawerOpen:
                                          (widget.drawerCtrl.drawerOpen ||
                                              widget
                                                  .drawerCtrl
                                                  .switchingToDrawer) &&
                                          widget.drawerCtrl.activePanel ==
                                              DrawerPanel.magic,
                                      isQuickRepliesOpen:
                                          (widget.drawerCtrl.drawerOpen ||
                                              widget
                                                  .drawerCtrl
                                                  .switchingToDrawer) &&
                                          widget.drawerCtrl.activePanel ==
                                              DrawerPanel.quickReplies,
                                      virtualKeyboardSend:
                                          widget.virtualKeyboardSend,
                                      enterToSend: widget.enterToSend,
                                      canSend: () =>
                                          _ensurePersonaSelected() &&
                                          _ensureApiSelected(),
                                      onSend: (text) {
                                        if (text.trim().isEmpty) return;
                                        _webViewStateKey.currentState
                                            ?.requestScrollToBottomOnAppend();
                                        ref
                                            .read(
                                              chatProvider(
                                                widget.charId,
                                              ).notifier,
                                            )
                                            .sendMessage(text);
                                      },
                                      onSendWithGuidance: (text, guidance) {
                                        if (text.trim().isEmpty) return;
                                        _webViewStateKey.currentState
                                            ?.requestScrollToBottomOnAppend();
                                        ref
                                            .read(
                                              chatProvider(
                                                widget.charId,
                                              ).notifier,
                                            )
                                            .sendMessage(
                                              text,
                                              guidanceText: guidance,
                                            );
                                      },
                                      onSendWithImage:
                                          (text, guidanceText, imageDataUrl) {
                                            _webViewStateKey.currentState
                                                ?.requestScrollToBottomOnAppend();
                                            ref
                                                .read(
                                                  chatProvider(
                                                    widget.charId,
                                                  ).notifier,
                                                )
                                                .sendMessage(
                                                  text,
                                                  guidanceText: guidanceText,
                                                  imageDataUrl: imageDataUrl,
                                                );
                                          },
                                      isGenerating: widget.state.isGenerating,
                                      isGeneratingImage:
                                          widget.state.isGeneratingImage,
                                      isPostGenRunning:
                                          widget.state.isPostGenRunning,
                                      onStop:
                                          (widget.state.isGenerating ||
                                              widget.state.isGeneratingImage ||
                                              widget.state.isPostGenRunning)
                                          ? () {
                                              final notifier = ref.read(
                                                chatProvider(
                                                  widget.charId,
                                                ).notifier,
                                              );
                                              if (widget
                                                      .state
                                                      .isGeneratingImage &&
                                                  !widget.state.isGenerating) {
                                                notifier
                                                    .cancelImageGeneration();
                                              } else {
                                                notifier.abortGeneration();
                                              }
                                            }
                                          : null,
                                      onMagicDrawer: () => widget.drawerCtrl
                                          .toggleDrawer(context),
                                      onQuickReplies: () =>
                                          widget.drawerCtrl.toggleDrawer(
                                            context,
                                            panel: DrawerPanel.quickReplies,
                                          ),
                                      onImpersonate: (guidance) => ref
                                          .read(
                                            chatProvider(
                                              widget.charId,
                                            ).notifier,
                                          )
                                          .impersonate(guidanceText: guidance),
                                      charId: widget.charId,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
