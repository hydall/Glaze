import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/debug/perf_debug.dart';
import '../../core/llm/game_time.dart';
import '../../core/models/character.dart';
import '../../core/services/file_export_service.dart';
import '../../core/utils/image_src.dart';
import '../../core/utils/error_format.dart';
import '../../core/utils/platform_paths.dart';
import '../../shared/widgets/glaze_spinner.dart';
import 'editing_message_provider.dart';

import '../../core/state/character_provider.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/memory_settings_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/state/studio_turn_config_resolver.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/shell/desktop/desktop_layout_provider.dart'
    show isDesktopLayout;
import '../../shared/shell/shell_header_provider.dart' show DetachedShellHost;
import '../../shared/shell/title_bar_header.dart';
import 'widgets/chat_column_width.dart';
import 'widgets/chat_header_search.dart';
import 'widgets/message_actions.dart';
import 'widgets/message_delete_confirmation.dart';
import 'widgets/output_limit_sheet.dart';
import 'widgets/game_time_seed_dialog.dart';
import '../../shared/theme/theme_font_provider.dart';
import '../../shared/theme/theme_preset.dart';
import '../../shared/theme/theme_provider.dart';
import '../../shared/theme/theme_settings_schema.dart';

import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../translation/message_translation_controller.dart';
import '../translation/translation_service.dart';
import '../../shared/widgets/image_viewer.dart';
import '../character_list/character_detail_screen.dart';
import '../guides/guide_anchor.dart';
import '../guides/guide_service.dart';
import '../image_gen/image_gen_provider.dart';
import '../personas/persona_list_provider.dart';
import '../personas/persona_list_screen.dart';
import '../presets/preset_editor_screen.dart';
import '../settings/api_list_provider.dart';
import '../settings/api_settings_screen.dart';
import '../settings/context_budget_check.dart';
import '../settings/app_settings_provider.dart';
import 'chat_drawer_controller.dart'
    show ChatDrawerController, kKeyboardHeightPref;
import 'chat_provider.dart';
import 'controllers/chat_message_selection_controller.dart';
import 'chat_search_delegate.dart';
import 'chat_state.dart';
import 'state/chat_body_selectors.dart';
import 'state/chat_drawer_editing_provider.dart';
import 'state/lorebook_coverage_provider.dart';
import 'state/memory_activity_provider.dart';
import 'state/studio_history_rotation_provider.dart';
import 'bridge/chat_webview_environment.dart'
    show chatWebViewResolveLocalFileUrl;
import 'chrome/chat_chrome_channel.dart';
import 'chrome/chat_composer_host.dart';
import 'chrome/chat_drawer_host.dart';
import 'chrome/chrome_json.dart';
import 'widgets/chat_header.dart';
import 'widgets/context_coverage_card.dart';
import 'widgets/memory_sheet.dart';
import 'widgets/studio_history_rotation_sheet.dart';
import 'widgets/post_cleaner_status_card.dart';
import 'widgets/post_gen_status_card.dart';
import 'widgets/studio_status_card.dart';
import 'widgets/chat_webview_widget.dart';
import 'widgets/triggered_items_sheet.dart';
import 'widgets/webview_callbacks.dart';
import '../../core/models/chat_message.dart';
import '../../core/state/db_provider.dart';
import 'widgets/session_lifecycle_tracker.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../plugins/runtime/plugin_chat_host.dart';
import '../plugins/providers/plugin_library_provider.dart';
import '../plugins/widgets/plugin_holes.dart';
import '../plugins/widgets/plugin_layer.dart';

String _chatWebViewThemeSyncKey(
  ThemePreset preset,
  String chatLayout,
  Brightness brightness,
  double avatarRoundness,
) {
  return [
    // A "same as device" theme repaints with different colors when only the
    // brightness changes.
    brightness.name,
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
    avatarRoundness,
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

  /// The header, composer and drawer, drawn in the chat WebView (see
  /// `assets/chat_webview/chrome/`). This screen sends the header's state and
  /// the theme; the body sends the rest.
  final ChatChromeChannel _chrome = ChatChromeChannel();
  late final VoidCallback _removeHeaderIntents;

  /// The UI font file last sent to the chrome. Compared by identity: it is a
  /// whole font as a data URL.
  String? _sentFontData;
  bool _fontSent = false;

  /// Guards against queueing one post-frame recount per rebuild while a
  /// search is open.
  bool _searchRecountScheduled = false;

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
    _removeHeaderIntents = _chrome.onAll({
      'back': (_) => _handleBack(),
      'openCharCard': (_) => unawaited(_showCharacterCard(widget.charId)),
      'openAvatar': (_) {
        final path = ref.read(characterByIdProvider(widget.charId))?.avatarPath;
        if (path != null && path.isNotEmpty) _showAvatarViewer(path);
      },
      'searchOpen': (_) {
        if (!_search.showSearch) _search.openSearch();
      },
      'searchInlineOpen': (_) => _search.openInline(),
      'searchClose': (_) => _search.closeSearch(),
      'searchQuery': (d) {
        final q = d['q'];
        if (q is! String) return;
        final messages =
            ref.read(chatProvider(widget.charId)).value?.messages ?? const [];
        _search.searchController.value = TextEditingValue(
          text: q,
          selection: TextSelection.collapsed(offset: q.length),
        );
        if (d['inline'] == true) {
          _search.syncInlineQuery(q, messages);
        } else {
          _search.search(q, messages);
        }
      },
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeShowGuide(context, AppGuide.chat);
    });
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

  /// Keeps the open search in sync with the chat.
  ///
  /// Editing a message (or deleting one, or swiping a variation) does not go
  /// through the search field's `onChanged`, so the delegate kept serving the
  /// match list it built when the query was typed: the "n / m" counter and the
  /// WebView highlights both went stale. Re-counting cannot happen inside
  /// `build` — the delegate notifies its listeners, and this state's listener
  /// calls `setState` — so it is deferred to the end of the frame.
  void _scheduleSearchRecount() {
    if (!_search.showSearch || _search.searchQuery.isEmpty) return;
    if (_searchRecountScheduled) return;
    _searchRecountScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchRecountScheduled = false;
      if (!mounted) return;
      final state = ref.read(chatProvider(widget.charId)).value;
      if (state == null || state.isGenerating) return;
      _search.syncWithMessages(state.messages);
    });
  }

  @override
  void dispose() {
    _removeHeaderIntents();
    _chrome.dispose();
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
          prefix: 'error_open_chat_session_failed'.tr(),
        );
      }
    } catch (e) {
      if (mounted && epoch == _applyEpoch) {
        GlazeErrorDialog.show(
          context,
          e,
          prefix: 'error_open_chat_session_failed'.tr(),
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
    PerfDebug.chatScreenBuilt();
    final charId = widget.charId;
    final chatStateAsync = ref.watch(chatProvider(charId));
    final chatState = chatStateAsync.value;
    if (chatState != null && !chatState.isGenerating) {
      _scheduleSearchRecount();
    }

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
    final enterToSend = appSettings?.enterToSend ?? false;
    final batterySaver = appSettings?.batterySaver ?? false;
    _drawerCtrl.setBatterySaverMode(batterySaver);

    // Does the chat body paint a background *image* of its own? When it does,
    // the scaffold's [GlazeBackground] underneath is dead work: the WebView's
    // #bg-layer holds the visible copy and `ChatWebViewSurface._background`
    // already covers the whole body with an opaque base + the same image, so
    // the scaffold's copy decodes and paints a full-screen image nobody sees.
    //
    // Only the image case is dropped. Without one the WebView paints no
    // background at all (#bg-layer goes `display: none`), so the colour comes
    // from Flutter alone and the cheap scaffold layer stays as the safety net
    // — as it does for the loading/error branches below, which render instead
    // of the chat body and would otherwise sit on nothing.
    final chatBg = batteryAware(
      ref,
      batterySaver,
      themeProvider.select(
        (t) => (
          mode: t.activePreset.chatBgMode,
          hasGlobalImage: t.activePreset.hasBgImage,
          hasCustomImage: t.activePreset.hasChatBgImage,
        ),
      ),
    );
    final avatarPath = character?.avatarPath;
    final bodyPaintsBgImage = switch (chatBg.mode) {
      'color' => false,
      'custom' => chatBg.hasCustomImage,
      'avatar' => avatarPath != null && avatarPath.isNotEmpty,
      _ => chatBg.hasGlobalImage,
    };

    // Under the app's title bar the header is one slim row: the character on
    // the left, the search field on the right with the bar's other buttons.
    final inTitleBar = TitleBarHeaderScope.of(context);

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

    // Built before the scaffold, not inside its argument list: the data branch
    // below is what sets `_everBuiltBody`, and `showBackground` reads it. Read
    // in argument order, the flag was a build late — the first build after the
    // body appeared still asked for the background wrapper and the next one
    // dropped it, so every chat open restructured the scaffold under the chat
    // body while the WebView was still wiring itself up.
    final body = chatStateAsync.when(
      loading: () => const Center(child: GlazeSpinner()),
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
          return const Center(child: GlazeSpinner());
        }
        _everBuiltBody = true;
        return ChatColumnWidth(
          child: Stack(
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
                chrome: _chrome,
              ),
              if (awaitingTargetSession)
                const Positioned.fill(
                  child: AbsorbPointer(
                    child: ColoredBox(
                      color: Colors.transparent,
                      child: Center(child: GlazeSpinner()),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );

    _publishChrome(
      character: character,
      sessionName: sessionName,
      inTitleBar: inTitleBar,
      batterySaver: batterySaver,
    );

    // Plugins run inside this chat's WebView; the host starts them once the
    // bridge is up and feeds them chat/message events.
    final tracked = SessionLifecycleTracker(
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
        // `_everBuiltBody` / `hasError`: the spinner and error branches below
        // render instead of the chat body, so they still need the scaffold's
        // background to sit on.
        showBackground:
            !(bodyPaintsBgImage && _everBuiltBody && !chatStateAsync.hasError),
        extendBodyBehindHeader: true,
        resizeToAvoidBottomInset: false,
        // The floating header is drawn by the chat page (see _publishChrome);
        // only under the app's title bar or in a window is it Flutter's.
        drawHeader: false,
        // Desktop paints a tab's header edge to edge (see the shell's
        // _DesktopHeader); chat matches it instead of floating a pill.
        flushHeader: isDesktopLayout(context),
        hideHeader: _isHeaderHidden,
        title: title,
        // Desktop swaps only the character block for its own field, from the
        // toggle after the session name (see [DesktopChatHeaderSearch]).
        titleWidget: _search.showSearch && !isDesktopLayout(context)
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
            : (character != null && inTitleBar
                  ? DesktopChatHeaderSearch(
                      search: _search,
                      charId: charId,
                      inTitleBar: true,
                      headerBuilder: (toggle) => ChatHeader(
                        character: character,
                        sessionName: sessionName,
                        currentSessionIndex: sessionIndex,
                        compact: true,
                        trailing: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: toggle,
                        ),
                        onTapInfo: () => _showCharacterCard(charId),
                        onTapAvatar:
                            (character.avatarPath != null &&
                                character.avatarPath!.isNotEmpty)
                            ? () => _showAvatarViewer(character.avatarPath!)
                            : null,
                      ),
                    )
                  : character != null
                  ? _buildCharacterHeader(
                      character: character,
                      charId: charId,
                      sessionName: sessionName,
                      sessionIndex: sessionIndex,
                    )
                  : null),
        onBack: _handleBack,
        // Desktop keeps the search toggle in the header itself, right after
        // the session name (see [DesktopChatHeaderSearch]).
        actions: _search.showSearch || isDesktopLayout(context)
            ? const []
            : [
                GuideAnchor(
                  id: GuideIds.chatSearch,
                  child: IconButton(
                    icon: const Icon(Icons.search),
                    color: context.cs.primary,
                    onPressed: () {
                      _search.openSearch();
                    },
                  ),
                ),
              ],
        body: body,
      ),
    );
    // Chat panels of plugins draw over everything of the chat screen.
    final useLayer = pluginsUseLayer(ref.watch(enabledPluginsProvider));
    return PluginChatHost(
      key: ValueKey('plugins-$charId'),
      charId: charId,
      child: useLayer
          ? Stack(
              fit: StackFit.expand,
              children: [
                tracked,
                PluginLayer(
                  key: ValueKey('plugin-layer-$charId'),
                  charId: charId,
                ),
              ],
            )
          : tracked,
    );
  }

  /// Dismisses whatever is open, innermost first, and leaves the chat when
  /// nothing is.
  ///
  /// Close the drawer BEFORE looking at the input focus. The composer's focus
  /// is the page's: tapping elsewhere in the WebView can leave it reported
  /// focused with no keyboard on screen. Checking focus first then swallowed
  /// the back on a no-op unfocus — the drawer never closed, and leaving the
  /// chat took a second press. Draining the visible overlays first keeps a
  /// stale focus flag from eating the gesture.
  void _handleBack() {
    if (!mounted) return;
    if (_drawerCtrl.drawerOpen || _drawerCtrl.switchingToDrawer) {
      _drawerCtrl.closeDrawer();
      return;
    }
    if (_search.showSearch || _search.inlineOpen) {
      _search.closeSearch();
      return;
    }
    // Only consume the back to dismiss the keyboard when it is genuinely up.
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_drawerCtrl.inputFocus.hasFocus && keyboardUp) {
      _drawerCtrl.inputFocus.unfocus();
      return;
    }
    // Nothing left to dismiss — leave the chat, without the keyboard.
    if (_drawerCtrl.inputFocus.hasFocus) {
      _drawerCtrl.inputFocus.unfocus();
    }
    context.go('/');
  }

  /// Sends the chrome its theme and the header's state.
  void _publishChrome({
    required Character? character,
    required String sessionName,
    required bool inTitleBar,
    required bool batterySaver,
  }) {
    final preset = batteryAware(
      ref,
      batterySaver,
      themeProvider.select((t) => t.activePreset),
    );
    final desktop = isDesktopLayout(context);
    _chrome.set('skin', preset.chromeLayoutPayload);
    _chrome.set(
      'theme',
      chromeTheme(
        context,
        preset,
        batterySaver: batterySaver,
        desktop: desktop,
        fontFamily: ref.watch(uiFontFamilyProvider).value,
      ),
    );
    final fontData = ref.watch(uiFontDataProvider).value;
    if (!_fontSent || !identical(fontData, _sentFontData)) {
      _fontSent = true;
      _sentFontData = fontData;
      _chrome.set(
        'font',
        chromeFont(fontData, variable: preset.uiFontMode == 'glaze'),
      );
    }

    // Under the app's title bar, and in a window of its own, the window's bar
    // is the header (Flutter's, through GlazeScaffold).
    final inPage = !inTitleBar && !DetachedShellHost.drawsChrome(context);
    final avatarVersion = ref.watch(avatarVersionProvider);
    Color avatarColor = context.cs.primary;
    final hex = character?.color;
    if (hex != null && hex.isNotEmpty) {
      try {
        avatarColor = Color(
          int.parse('FF${hex.replaceFirst('#', '')}', radix: 16),
        );
      } catch (_) {}
    }
    final avatarPath = character?.avatarPath;
    final avatarUrl = avatarPath == null || avatarPath.isEmpty
        ? null
        : chatWebViewResolveLocalFileUrl(avatarPath);
    final name = character?.name ?? '';
    _chrome.set('header', {
      'show': inPage,
      'hidden': _isHeaderHidden,
      'flush': desktop,
      'radius': 20,
      'title': name.isEmpty ? 'Chat' : name,
      'session': sessionName,
      'avatar': {
        'url': avatarUrl == null || avatarUrl.isEmpty
            ? null
            : '$avatarUrl&v=$avatarVersion',
        'color': chromeColor(avatarColor),
        'initial': name.isNotEmpty ? name[0].toUpperCase() : '?',
      },
      'search': {
        'kind': desktop ? 'desktop' : 'mobile',
        'open': desktop ? _search.inlineOpen : _search.showSearch,
        'hint': 'search_messages'.tr(),
        'closeHint': 'btn_close'.tr(),
      },
    });
  }

  /// The character block of the in-app (not title bar) header. Desktop adds
  /// the search toggle after the session name.
  Widget _buildCharacterHeader({
    required Character character,
    required String charId,
    required String sessionName,
    required int sessionIndex,
  }) {
    Widget header({Widget? trailing}) => GuideAnchor(
      id: GuideIds.chatHeader,
      child: ChatHeader(
        character: character,
        sessionName: sessionName,
        currentSessionIndex: sessionIndex,
        trailing: trailing,
        onTapInfo: () => _showCharacterCard(charId),
        onTapAvatar:
            (character.avatarPath != null && character.avatarPath!.isNotEmpty)
            ? () => _showAvatarViewer(character.avatarPath!)
            : null,
      ),
    );
    if (!isDesktopLayout(context)) return header();
    return DesktopChatHeaderSearch(
      search: _search,
      charId: charId,
      headerBuilder: (toggle) => header(
        trailing: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: toggle,
        ),
      ),
    );
  }

  /// Opens the character card (detail sheet) for [charId]. Mirrors
  /// [CharacterDetailSheetLauncher]: the sheet pops a route string when the
  /// user picks an action inside it (edit / gallery / open chat), which we
  /// forward to GoRouter.
  Future<void> _showCharacterCard(String charId) async {
    final navTarget = await showGlazeSheet<String>(
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

/// The round glass button floating over the chat that jumps to the top or the
/// bottom of the message list. One widget so the two jump buttons only differ
/// in icon, direction and callback.
class _ChatScrollButton extends StatelessWidget {
  const _ChatScrollButton({
    required this.visible,
    required this.icon,
    required this.onTap,
  });

  final bool visible;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        opacity: visible ? 1 : 0,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(0, 0.2),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
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
                child: Icon(icon, color: context.cs.primary, size: 26),
              ),
            ),
          ),
        ),
      ),
    );
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

  /// The chat chrome — header, composer and drawer — drawn in the WebView.
  final ChatChromeChannel chrome;

  const _ChatBody({
    required this.charId,
    required this.state,
    required this.drawerCtrl,
    required this.search,
    required this.keyboardHeight,
    this.onScrollDirection,
    this.virtualKeyboardSend = false,
    this.enterToSend = false,
    this.targetMessageId,
    this.isHeaderHidden = false,
    required this.chrome,
  });

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody>
    with WidgetsBindingObserver {
  /// Height of the composer, as the page reports it (see
  /// [ChromeLayoutReport.composerHeight]): what the message list keeps clear
  /// above the keyboard or drawer, and where the scroll buttons sit.
  double _inputBarHeight = 130.0;

  /// Last bottom inset (input bar + keyboard/drawer) pushed to the WebView.
  /// Cached so it can be re-asserted on app resume — see
  /// [didChangeAppLifecycleState].
  double _lastMessageListBottom = 0;

  /// Measured height of the floating [ContextCoverageCard] (0 when hidden) so
  /// the message list reserves room at the *top* for it — otherwise the card
  /// floats under the header and covers the first visible messages.
  double _contextCardHeight = 0.0;

  /// The same height, but frozen at the card's *collapsed* size.
  ///
  /// Only this one insets the message list. Reserving the expanded height too
  /// would rewrite the WebView's `padding-top` on every open/close, and the
  /// page keeps its `scrollTop` across that rewrite — so the chat visibly
  /// jumped each time the panel was toggled. The expanded body is an overlay
  /// instead: it floats over the first messages for as long as it is open and
  /// the list underneath never moves.
  double _contextCardCollapsedHeight = 0.0;
  final GlobalKey _contextCardKey = GlobalKey();

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
  bool _showScrollToTop = false;
  bool _contextCardExpanded = false;
  bool _showingHistoryRotation = false;
  final GlobalKey<ChatWebViewWidgetState> _webViewStateKey = GlobalKey();

  /// Content already auto-translated per arriving message id, so a settled
  /// turn is not translated again by a later rebuild — but a rewrite is.
  final Map<String, String> _autoTranslatedMessages = {};

  /// The per-message translate button. Display-only: the translation is
  /// painted in the WebView and never reaches the message or the prompt.
  late final MessageTranslationController _translations =
      MessageTranslationController(
        view: MessageTranslationView(
          showPending: (id, original, label, deferred) =>
              _webViewStateKey.currentState?.setTranslationPending(
                id,
                original,
                label,
                deferred: deferred,
              ) ??
              Future.value(false),
          showTranslation: (id, original, text, deferred) =>
              _webViewStateKey.currentState?.setTranslation(
                id,
                original,
                text,
                deferred: deferred,
              ) ??
              Future.value(),
          showOriginal: (id) =>
              _webViewStateKey.currentState?.clearTranslation(id) ??
              Future.value(),
        ),
        onError: (error) {
          if (!mounted) return;
          GlazeToast.show(
            context,
            error is TranslationNotConfiguredException
                ? 'translation_not_configured'.tr()
                : 'translation_failed'.tr(args: [formatError(error)]),
            isError: true,
          );
        },
      );

  void _onTranslateMessage(String id, String action, String text) {
    final settings = ref.read(pipelineSettingsProvider).translation;
    if (!settings.enabled) return;
    // Claim the message so an automatic pass does not undo a manual choice.
    _autoTranslatedMessages[id] = text;
    final sessionId = widget.state.session?.id;
    // The language the reader reads in: the one picked, or the interface's.
    final target = settings.messageLanguage.isNotEmpty
        ? settings.messageLanguage
        : context.locale.languageCode;
    unawaited(
      _translations.handle(
        id: id,
        action: action,
        text: text,
        pendingLabel: 'translation_in_progress'.tr(),
        translate: (text, token) => ref
            .read(translationServiceProvider)
            .translate(
              text: text,
              targetLanguageCode: target,
              cancelToken: token,
              sessionId: sessionId,
              messageId: id,
            ),
      ),
    );
  }

  /// Translates an arriving character message into the reader's language, once
  /// the turn has settled. Display-only: the pending bubble names the phase,
  /// then the translation is painted over the message and the stored text — and
  /// the context the model continues from — stays original.
  ///
  /// Keyed by message id and content, not by a one-shot flag: a post-generation
  /// stage (the Studio cleaner) can rewrite the message after the stream ends,
  /// and the newer text is translated in turn. A manual translate marks the
  /// message too, so an automatic pass never overrides a choice the reader made.
  void _maybeAutoTranslateLastMessage(ChatState state) {
    if (state.isGenerating || state.isPostGenRunning || state.isSendPending) {
      return;
    }
    final settings = ref.read(pipelineSettingsProvider).translation;
    if (!settings.enabled || !settings.autoTranslateCharacter) return;
    final messages = state.messages;
    if (messages.isEmpty) return;
    final last = messages.last;
    if (last.role != 'assistant' ||
        last.isTyping ||
        last.content.trim().isEmpty) {
      return;
    }
    if (_autoTranslatedMessages[last.id] == last.content) return;
    _autoTranslatedMessages[last.id] = last.content;
    final target = settings.messageLanguage.isNotEmpty
        ? settings.messageLanguage
        : context.locale.languageCode;
    unawaited(
      _translations.handle(
        id: last.id,
        action: 'translate',
        text: last.content,
        pendingLabel: 'gen_phase_translating_character'.tr(),
        translate: (text, token) => ref
            .read(translationServiceProvider)
            .translate(
              text: text,
              targetLanguageCode: target,
              cancelToken: token,
              sessionId: state.session?.id,
              messageId: last.id,
            ),
        deferred: true,
      ),
    );
  }

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
    if (oldWidget.state.session?.id != widget.state.session?.id) {
      _translations.cancelAll();
      _autoTranslatedMessages.clear();
    }
    _maybeAutoTranslateLastMessage(widget.state);
    if (oldWidget.drawerCtrl != widget.drawerCtrl) {
      _bindDrawerListenable();
    }
    if (oldWidget.charId != widget.charId ||
        oldWidget.state.session?.id != widget.state.session?.id) {
      _publishOpenChat();
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
    // Plugins report where they draw in the WebView's own coordinates. In
    // the plugin layer, that is the layer's (see [PluginLayer]).
    if (!pluginLayerSupported()) {
      ref.read(pluginHolesProvider(widget.charId)).page = () =>
          _webViewStateKey.currentContext;
    }
    widget.chrome.layout.addListener(_onChromeLayout);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkHeight());
    _publishOpenChat();
    final targetId = widget.targetMessageId;
    if (targetId != null && targetId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_scrollToTargetMessage(targetId)),
      );
    }
  }

  void _onChromeLayout() {
    if (!mounted) return;
    final height = widget.chrome.layout.value.composerHeight;
    if (height > 0 && (height - _inputBarHeight).abs() >= 0.5) {
      setState(() => _inputBarHeight = height);
    }
  }

  /// Records this chat and its session as the one the user is in, for the
  /// screens that show its persona from outside it. Deferred: providers may
  /// not change while the tree builds.
  void _publishOpenChat() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = (charId: widget.charId, sessionId: widget.state.session?.id);
      if (ref.read(lastOpenChatProvider) == key) return;
      ref.read(lastOpenChatProvider.notifier).state = key;
    });
  }

  /// Waits for the keep-alive WebView to finish initializing, then scrolls to
  /// and flashes the message that a tapped notification points at. Mirrors
  /// Vue's openChat(msgId) → scrollToAnchor + search-highlight behaviour.
  ///
  /// A notification tap also selects the session the message landed in, and
  /// that switch is asynchronous. So readiness is not just "the WebView is up":
  /// the target message has to be in the session currently loaded, or the
  /// scroll would run against the chat that was open before the switch and
  /// quietly do nothing.
  Future<void> _scrollToTargetMessage(String messageId) async {
    const tick = Duration(milliseconds: 100);
    for (var i = 0; i < 100; i++) {
      if (!mounted) return;
      final st = _webViewStateKey.currentState;
      if (st == null || !st.isReady) {
        await Future<void>.delayed(tick);
        continue;
      }
      final loaded =
          ref
              .read(chatProvider(widget.charId))
              .value
              ?.messages
              .any((m) => m.id == messageId) ??
          false;
      if (!loaded) {
        await Future<void>.delayed(tick);
        continue;
      }
      // Let the initializer's opening scroll-to-bottom settle before
      // retargeting, otherwise the two scrolls fight each other.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      await st.scrollToMessage(messageId, highlight: true);
      return;
    }
  }

  void _checkHeight() {
    if (!mounted) return;
    var changed = false;
    var nextContextCardHeight = _contextCardHeight;
    var nextContextCardCollapsedHeight = _contextCardCollapsedHeight;
    var nextWebViewBoxHeight = _webViewBoxHeight;

    // The context card is only mounted while visible. When it is absent its
    // reserved top height collapses back to 0 so the list reclaims the space.
    final contextHeight = _contextCardKey.currentContext?.size?.height ?? 0.0;
    if (contextHeight != _contextCardHeight) {
      nextContextCardHeight = contextHeight;
      changed = true;
    }

    // The reserve follows the card only while it is collapsed (and all the way
    // down to 0 when it unmounts). While it is expanded the last collapsed
    // height stands, so opening the panel never moves the message list.
    final reserveHeight = (_contextCardExpanded && contextHeight > 0)
        ? _contextCardCollapsedHeight
        : contextHeight;
    if (reserveHeight != _contextCardCollapsedHeight) {
      nextContextCardCollapsedHeight = reserveHeight;
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
        _contextCardHeight = nextContextCardHeight;
        _contextCardCollapsedHeight = nextContextCardCollapsedHeight;
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

  Future<void> _scrollToTop() async {
    final webViewState = _webViewStateKey.currentState;
    if (webViewState != null) {
      await webViewState.scrollToTop();
    }
    if (!mounted) return;
    setState(() => _showScrollToTop = false);
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

  /// Saves a generated image to the public Glaze downloads folder
  /// (`Downloads/Glaze/images`), with no share sheet in the way.
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

      final path = await FileExportService.saveBytesToGlaze(
        bytes: bytes,
        filename: 'glaze_image_${DateTime.now().millisecondsSinceEpoch}.$ext',
        subfolder: 'images',
      );
      if (path.isEmpty) return;
      if (mounted) GlazeToast.show(context, 'export_success'.tr());
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
  /// Glaze useMessageImageGen.js): Expand → fullscreen, Save → Glaze folder,
  /// Regenerate → re-run image generation for the owning message. The
  /// Regenerate entry is hidden when the owning message can't be resolved in
  /// the current list (no messageId, or the message is already gone).
  ///
  /// Uses [GlazeBottomSheet] so the sheet matches every other action sheet in
  /// the app (glass surface, handle bar, haptics) instead of a bare Material
  /// `showModalBottomSheet`.
  /// Actions for one image of a message. [blockIndex] is the position of that
  /// image inside the message, so regenerating or recovering it leaves the
  /// other images alone; a failed block opens the same sheet without the
  /// view/save entries it has no file for.
  void _showImageOptionsSheet(
    String src,
    String instruction,
    String messageId,
    int? blockIndex,
  ) {
    final messages = widget.state.messages;
    final idx = messageId.isEmpty
        ? -1
        : messages.indexWhere((m) => m.id == messageId);
    final hasImage = src.isNotEmpty;
    // Markdown images carry no block index — they are not generated, so the
    // generation actions do not apply to them.
    final isGenBlock = idx >= 0 && blockIndex != null;

    GlazeBottomSheet.show<void>(
      context,
      items: [
        if (hasImage)
          BottomSheetItem(
            icon: Icons.fullscreen,
            label: 'imggen_expand_image'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _showImageViewer(context, src);
            },
          ),
        if (hasImage)
          BottomSheetItem(
            icon: Icons.save_alt,
            label: 'action_save_image'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _downloadImage(src);
            },
          ),
        if (isGenBlock)
          BottomSheetItem(
            icon: Icons.refresh,
            label: 'action_regenerate'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(chatProvider(widget.charId).notifier)
                  .retryImageGenerationForMessage(
                    messageId,
                    blockIndex: blockIndex,
                  );
            },
          ),
        if (isGenBlock && !hasImage)
          BottomSheetItem(
            icon: Icons.search,
            label: 'imggen_find_on_disk'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              ref
                  .read(chatProvider(widget.charId).notifier)
                  .findImageOnDisk(
                    messageId,
                    instruction,
                    blockIndex: blockIndex,
                  );
            },
          ),
      ],
    );
  }

  /// Before the first message of a Studio chat with Ledger enabled, require a
  /// complete world:date/day/time tuple. Ordinary chats never enter this path.
  Future<bool> _maybeSeedGameTime() async {
    try {
      final session = widget.state.session;
      if (session == null) return false;
      bool isCurrentSession() =>
          mounted &&
          ref.read(chatProvider(widget.charId)).value?.session?.id ==
              session.id;
      if (widget.state.messages.any((m) => m.role == 'user')) return true;
      final turnConfig = await ref
          .read(studioTurnConfigResolverProvider)
          .resolve(session.id);
      if (!isCurrentSession()) return false;
      if (!turnConfig.enabled || !turnConfig.ledgerEnabled) return true;
      final trackerRepo = ref.read(trackerRepoProvider);
      final existing = await Future.wait([
        trackerRepo.get(session.id, GameTimeState.timeKey),
        trackerRepo.get(session.id, GameTimeState.dateKey),
        trackerRepo.get(session.id, GameTimeState.dayKey),
      ]);
      if (!isCurrentSession()) return false;
      if (GameTimeState.fromTrackers(existing.nonNulls).format() != null) {
        return true;
      }
      if (!mounted) return false;
      final result = await GlazeBottomSheet.show<GameTimeSeedResult>(
        context,
        title: 'game_time_seed_title'.tr(),
        isDismissible: false,
        locked: true,
        child: const GameTimeSeedDialog(),
      );
      if (result == null) return false;
      if (!isCurrentSession()) return false;
      final seeded = await trackerRepo.seedInitialGameTime(
        sessionId: session.id,
        time: result.time,
        date: result.date,
        expectedValues: {
          GameTimeState.timeKey: existing[0]?.value,
          GameTimeState.dateKey: existing[1]?.value,
          GameTimeState.dayKey: existing[2]?.value,
        },
      );
      return seeded && isCurrentSession();
    } catch (_) {
      return false;
    }
  }

  /// Guards message sending behind an explicitly selected persona. When no
  /// persona is selected in the persona list, shows a notice sheet with a
  /// shortcut to pick one and returns false so the caller aborts the send.
  bool _ensurePersonaSelected() {
    if (ref.read(activePersonaIdProvider) != null) return true;
    // A persona bound to this chat or its character is a selection too.
    if (hasPersonaBinding(
      ref.read(personaListProvider).value ?? const [],
      ref.read(personaConnectionsProvider),
      (charId: widget.charId, sessionId: widget.state.session?.id),
    )) {
      return true;
    }
    GlazeBottomSheet.show<void>(
      context,
      title: 'persona_required_title'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.person_off_outlined,
        description: 'persona_required_desc'.tr(),
        buttonText: 'persona_required_select'.tr(),
        onButtonTap: () {
          Navigator.of(context, rootNavigator: true).pop();
          showGlazeSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const PersonaListScreen(forChat: true),
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
          showGlazeSheet<void>(
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

  /// The guard a quick reply runs before it sends or continues: the same
  /// context check the composer's send makes, then the game-time seed.
  Future<bool> _beforeQuickReply() async =>
      _ensureContextFits() && await _maybeSeedGameTime();

  /// Blocks a send the context window cannot carry: when the chat's preset
  /// alone outgrows what the window leaves after the reply's reservation, the
  /// history trim keeps no message — not even the one being sent — so the
  /// request would go out without the chat. Shows the API settings' hint
  /// instead and returns false so the caller aborts the send.
  bool _ensureContextFits() {
    // Studio builds the final prompt without the chat preset, from its own
    // connection's window.
    if (ref.read(studioFeatureEnabledProvider)) return true;
    final api = ref.read(activeApiConfigProvider);
    if (api == null) return true;
    final preset = ref.read(
      effectivePresetForChatProvider((
        charId: widget.charId,
        sessionId: widget.state.session?.id,
      )),
    );
    if (preset == null) return true;
    final fits = presetFitsContext(
      presetTokens: presetPromptTokens(preset),
      contextSize: api.contextSize,
      maxTokens: api.maxTokens,
    );
    if (fits) return true;
    GlazeBottomSheet.show<void>(
      context,
      title: 'preset_exceeds_context_title'.tr(),
      child: Builder(
        builder: (sheetContext) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 64,
                color: sheetContext.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              PresetFitWarningText(
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: sheetContext.cs.onSurface,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(sheetContext, rootNavigator: true).pop();
                    unawaited(
                      showApiSettingsSheet(
                        context,
                        focusSection: ApiSettingsSection.context,
                      ),
                    );
                  },
                  child: Text('api_required_select'.tr()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keyboardSettleTimer?.cancel();
    _translations.cancelAll();
    widget.chrome.layout.removeListener(_onChromeLayout);
    super.dispose();
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
    ref.listen<StudioHistoryRotationNotice?>(
      studioHistoryRotationProvider(widget.charId),
      (previous, notice) {
        if (notice == null ||
            notice.sessionId != widget.state.session?.id ||
            _showingHistoryRotation) {
          return;
        }
        ref.read(studioHistoryRotationProvider(widget.charId).notifier).state =
            null;
        _showingHistoryRotation = true;
        unawaited(
          showStudioHistoryRotationSheet(
            context,
            droppedMessageCount: notice.droppedMessageCount,
          ).then((action) async {
            if (!mounted) return;
            _showingHistoryRotation = false;
            if (action == StudioHistoryRotationAction.memory) {
              if (!context.mounted) return;
              await showMemorySheet(
                context,
                widget.charId,
                initialTab: MemoryTab.books,
              );
            }
          }),
        );
      },
    );
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
              Widget editor(BuildContext _) =>
                  PresetEditorScreen(preset: preset, charId: widget.charId);
              // On desktop a window over the chat; a page would cover the
              // whole app.
              if (isDesktopLayout(context)) {
                showGlazeSheet<void>(
                  context: context,
                  useRootNavigator: true,
                  builder: editor,
                );
              } else {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: editor));
              }
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
    // The context card under the header: an opt-out in the interface settings,
    // and it only earns its space when a layer has something to report.
    final contextCardEnabled = !(appSettings?.hideContextCard ?? false);
    final hasMemoryActivity =
        memoryEnabled &&
        memoryActivity != null &&
        memoryActivity.hasDiagnostics;
    // Subscribed to only while the card can actually show it — the coverage
    // provider runs a full keyword scan (and, with embeddings configured, a
    // vector query) per turn.
    final lorebookCandidates = contextCardEnabled
        ? ref.watch(
            lorebookCoverageProvider(
              widget.charId,
            ).select((v) => v.value?.totalCandidates ?? 0),
          )
        : 0;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final messageListTop = MediaQuery.paddingOf(context).top + 10 + 56;

    final bgBlur = preset.bgBlur > 0 ? preset.bgBlur : 0.0;
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
        // The drawer height comes from the last keyboard, and some Android
        // keyboards report the whole window. Unclamped, the drawer covers the
        // page and leaves its own header above the screen; clamp it to the
        // usable height, below the status bar, both here and in the page.
        final drawerMaxHeight = math.max(
          0.0,
          MediaQuery.sizeOf(context).height - MediaQuery.paddingOf(context).top,
        );
        final drawerHeight = math.min(
          widget.drawerCtrl.activeDrawerHeight,
          drawerMaxHeight,
        );
        final targetDrawerInset = drawerActive ? drawerHeight * progress : 0.0;
        final panelHeight = math.max(targetDrawerInset, widget.keyboardHeight);
        final factor = math.min(1.0, panelHeight / math.max(1.0, safeBottom));
        final effectiveBottomInset = panelHeight + (safeBottom * (1 - factor));
        // The context card floats under the header (top of the chat). It is
        // shown when either retrieval layer has something to report, and can be
        // switched off entirely in the interface settings.
        final showContextCard =
            contextCardEnabled && (hasMemoryActivity || lorebookCandidates > 0);
        // When the card is dismissed its widget unmounts, so the size notifier
        // can't fire — reclaim the reserved top space on the next frame.
        if (!showContextCard && _contextCardHeight != 0.0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _checkHeight());
        }
        // Reserve room at the top so the card sits in a gap under the header
        // instead of covering the first visible messages. The gap above the
        // card is part of the reserve — the card is a separate surface from the
        // header, not a strip welded to its bottom edge.
        //
        // Only the collapsed height is reserved: the reserve is pushed to the
        // WebView as its top padding, and re-pushing it while the panel opens
        // would shift the messages under a stationary scroll offset. See
        // [_contextCardCollapsedHeight].
        final contextTopReserve = showContextCard
            ? kContextCardHeaderGap + _contextCardCollapsedHeight + 8
            : 0.0;
        final effectiveTopInset = messageListTop + contextTopReserve;
        // Where the card actually ends — the expanded body included. The
        // floating status cards stack below that, so an open panel does not
        // render underneath them.
        final contextCardBottom = showContextCard
            ? messageListTop + kContextCardHeaderGap + _contextCardHeight + 8
            : messageListTop;

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
        final drawerTargetInset = drawerActive ? drawerHeight : 0.0;
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
        // Editing needs no inset of its own: the Save/Cancel row is laid out
        // inside the edited message (see `.message-section.editing .msg-footer`
        // in assets/chat_webview/styles.css), so the message's own height
        // already carries it and this inset clears it like any other content.
        final webViewBottomInset =
            _inputBarHeight +
            targetPanelHeight +
            (safeBottom * (1 - targetFactor));
        _lastMessageListBottom = webViewBottomInset;
        final showScrollBtn =
            _showScrollToBottom &&
            !widget.search.showSearch &&
            !isEditingMessage;
        // JS arms this once the reader scrolls up away from the first message;
        // the header gate takes it away again on a downward scroll, matching
        // the header's own hide-on-scroll.
        final showScrollTopBtn =
            _showScrollToTop &&
            !widget.isHeaderHidden &&
            !widget.search.showSearch &&
            !isEditingMessage;

        final animatedBottomPanelInset =
            panelHeight + (safeBottom * (1 - factor));
        final renderDrawer =
            !isDesktopLayout(context) &&
            (widget.drawerCtrl.drawerOpen || progress > 0.001);

        // Where the composer and the drawer are, every frame of a keyboard
        // or drawer animation: the page moves them with the inset, which is
        // one small call and no relayout of the message list.
        widget.chrome.set('layout', {
          'safeTop': MediaQuery.paddingOf(context).top,
          'safeBottom': safeBottom,
          'inset': animatedBottomPanelInset,
          'viewportH': _webViewBoxHeight,
          'keyboard': widget.keyboardHeight,
          'softKeyboard':
              widget.keyboardHeight > 0 &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS),
          'gutter': ChatColumnScope.maybeOf(context)?.gutter ?? 0,
          // The fades under the header and the composer. Dropped on desktop:
          // the flush header is opaque enough on its own, and against the
          // even chat background the two bands only read as darkened edges.
          'fades': !isDesktopLayout(context),
          'drawer': {
            'show': renderDrawer,
            'height': drawerHeight,
            'progress': progress,
          },
        });

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

        final column = ChatColumnScope.maybeOf(context);
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
                        isSendPending: widget.state.isSendPending,
                        regenTargetId: widget.state.regenTargetId,
                        continuationTargetId: widget.state.continuationTargetId,
                        bottomInset: webViewBottomInset,
                        viewportHeight: _webViewBoxHeight,
                        topInset: effectiveTopInset,
                        chromeChannel: widget.chrome,
                        charName: character?.name,
                        charColor: character?.color,
                        personaName: effectivePersona?.name,
                        greetingTotal: greetingTotal,
                        chatLayout: preset.chatLayout,
                        themeLayout: switch (preset.messageLayoutPayload) {
                          null => null,
                          final layout => jsonEncode(layout),
                        },
                        themeSyncKey: _chatWebViewThemeSyncKey(
                          preset,
                          preset.chatLayout,
                          Theme.of(context).brightness,
                          preset.avatarRoundness,
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
                        avatarRoundness: preset.avatarRoundness,
                        charAvatarPath: character?.avatarPath,
                        personaAvatarPath: effectivePersona?.avatarPath,
                        bgImagePath: bgPath,
                        bgBlur: bgBlur,
                        bgNoiseOpacity: preset.bgNoiseOpacity,
                        bgNoiseIntensity: preset.bgNoiseIntensity,
                        bgDim: preset.bgDim.clamp(0.0, 1.0),
                        chatBgMode: preset.chatBgMode,
                        chatBgColor: preset.chatBgColorParsed,
                        chatFontName: fontStyle.fontFamily,
                        chatFontDataUrl: fontDataUrl,
                        chatFontSize: fontStyle.fontSize,
                        chatLetterSpacing: fontStyle.letterSpacing,
                        chatColumnWidth: column?.columnWidth ?? 0,
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
                        translationEnabled: ref.watch(
                          pipelineSettingsProvider.select(
                            (p) => p.translation.enabled,
                          ),
                        ),
                        messageActions: MessageActionsCallbacks(
                          onMessageContext:
                              (index, messageId, isUser, isSystem, content) {
                                showMessageContextMenu(
                                  context: context,
                                  ref: ref,
                                  charId: widget.charId,
                                  sessionId: widget.state.session?.id,
                                  content: content,
                                  messageIndex: index,
                                  messageId: messageId,
                                  isUser: isUser,
                                  isTyping:
                                      widget.state.isGenerating &&
                                      index == widget.state.messages.length - 1,
                                  isError: false,
                                  isLast:
                                      index == widget.state.messages.length - 1,
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
                                  beforeRegenerate: _maybeSeedGameTime,
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
                          onRegenerate: (id, mode) async {
                            if (!await _maybeSeedGameTime()) return;
                            await ref
                                .read(chatProvider(widget.charId).notifier)
                                .regenerateLastAssistant();
                          },
                          onRerunCleaner: (id) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .rerunCleaner(id);
                          },
                          onTranslateMessage: _onTranslateMessage,
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
                          onGuidedSwipe: (id, guidanceText) async {
                            final idx = widget.state.messages.indexWhere(
                              (m) => m.id == id,
                            );
                            if (idx < 0) return;
                            final msg = widget.state.messages[idx];
                            final isLastAssistant =
                                msg.role == 'assistant' &&
                                idx == widget.state.messages.length - 1;
                            if (isLastAssistant) {
                              if (!await _maybeSeedGameTime()) return;
                              await ref
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
                          onOutputLimitClick: (_) =>
                              showOutputLimitSheet(context),
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
                          onImgRetry: (instruction, messageId, blockIndex) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .retryImageGenerationForMessage(
                                  messageId,
                                  failedOnly: true,
                                  blockIndex: blockIndex,
                                );
                          },
                          onImgEnableRetry:
                              (instruction, messageId, blockIndex) async {
                                await ref
                                    .read(imageGenSettingsProvider.notifier)
                                    .updateEnabled(true);
                                if (!mounted) return;
                                await ref
                                    .read(chatProvider(widget.charId).notifier)
                                    .retryImageGenerationForMessage(
                                      messageId,
                                      failedOnly: true,
                                      blockIndex: blockIndex,
                                    );
                              },
                          onImgFind: (instruction, messageId, blockIndex) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .findImageOnDisk(
                                  messageId,
                                  instruction,
                                  blockIndex: blockIndex,
                                );
                          },
                          onImgRegen: (instruction, messageId, blockIndex) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .retryImageGenerationForMessage(
                                  messageId,
                                  blockIndex: blockIndex,
                                );
                          },
                          onImgCancel: () {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .cancelImageGeneration();
                          },
                          onImgDownload: _downloadImage,
                          onImgVariant: (messageId, blockIndex, variantIndex) {
                            ref
                                .read(chatProvider(widget.charId).notifier)
                                .selectImageVariant(
                                  messageId,
                                  blockIndex,
                                  variantIndex,
                                );
                          },
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
                          onScrollToTopVisibility: (visible) {
                            if (!mounted || _showScrollToTop == visible) {
                              return;
                            }
                            setState(() => _showScrollToTop = visible);
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
                        searchRevision: widget.search.searchRevision,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Everything laid over the WebView keeps to the capped column (see
            // [ChatColumnWidth]); the WebView alone spans the full width.
            Positioned.fill(
              left: column?.gutter ?? 0,
              right: column?.gutter ?? 0,
              child: PluginHolesCutter(
                holes: ref.watch(pluginHolesProvider(widget.charId)),
                enabled: !pluginLayerSupported(),
                child: Stack(
                  children: [
                    // The scroll-to-bottom button. Mirror Vue ChatInput
                    // (`v-if="!isSearchMode"`): it is suppressed while searching.
                    Positioned(
                      right: 16,
                      bottom: messageListBottom + 16,
                      child: _ChatScrollButton(
                        visible: showScrollBtn,
                        icon: Icons.keyboard_arrow_down_rounded,
                        onTap: _scrollToBottom,
                      ),
                    ),
                    // Context coverage panel: memory + lorebook for the next prompt.
                    // It sits under the header, separated by [kContextCardHeaderGap],
                    // and rides the header's own hide-on-scroll animation (same curve,
                    // same pixel travel — see
                    // [kGlazeHeaderHideDuration]), so the two slide away and come back
                    // as one unit. It cannot live inside GlazeScaffold's header itself:
                    // its measured height is what insets the top of the message list
                    // (see [_contextCardHeight]), and that measurement belongs to this
                    // body. The animation wrappers stay OUTSIDE the size notifier so
                    // the reserved space is the panel's natural height — the reserve
                    // does not collapse while the header is hidden, exactly like the
                    // header's own reserved strip.
                    if (showContextCard)
                      Positioned(
                        top: messageListTop + kContextCardHeaderGap,
                        left: 12,
                        right: 12,
                        child: IgnorePointer(
                          ignoring: widget.isHeaderHidden,
                          child: AnimatedSlide(
                            offset: widget.isHeaderHidden
                                ? Offset(
                                    0,
                                    -glazeHeaderHideSlideFor(
                                      // The panel is anchored below the header, one
                                      // gap down: `messageListTop` (safe-area top +
                                      // 10px padding + the 56px app bar) plus that gap
                                      // is how far it has to travel to clear it.
                                      headerHeight:
                                          messageListTop +
                                          kContextCardHeaderGap,
                                      overlayHeight: _contextCardHeight,
                                    ),
                                  )
                                : Offset.zero,
                            duration: kGlazeHeaderHideDuration,
                            curve: kGlazeHeaderHideCurve,
                            child: AnimatedOpacity(
                              opacity: widget.isHeaderHidden ? 0.0 : 1.0,
                              duration: kGlazeHeaderHideDuration,
                              curve: kGlazeHeaderHideCurve,
                              child:
                                  NotificationListener<
                                    SizeChangedLayoutNotification
                                  >(
                                    onNotification: (n) {
                                      WidgetsBinding.instance
                                          .addPostFrameCallback(
                                            (_) => _checkHeight(),
                                          );
                                      return true;
                                    },
                                    child: SizeChangedLayoutNotifier(
                                      child: Container(
                                        key: _contextCardKey,
                                        child: ContextCoverageCard(
                                          charId: widget.charId,
                                          memory: hasMemoryActivity
                                              ? memoryActivity
                                              : null,
                                          expanded: _contextCardExpanded,
                                          sessionId: widget.state.session?.id,
                                          onToggle: () {
                                            setState(() {
                                              _contextCardExpanded =
                                                  !_contextCardExpanded;
                                            });
                                          },
                                        ),
                                      ),
                                    ),
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
                      top: contextCardBottom,
                      child: const PostCleanerStatusCard(),
                    ),
                    // Studio tracker-cycle live status card. Shown during generation
                    // while Studio trackers / final generator are running.
                    Positioned(
                      left: 12,
                      right: 12,
                      top: contextCardBottom + 56,
                      child: const StudioStatusCard(),
                    ),
                    // Post-generation tasks (Ledger and extension blocks) live status.
                    Positioned(
                      left: 12,
                      right: 12,
                      top: contextCardBottom + 112,
                      child: PostGenStatusCard(
                        sessionId: widget.state.session?.id,
                      ),
                    ),
                    // Scroll-to-top: stacked directly above the scroll-to-bottom
                    // button in the bottom-right corner. It is gated on the header's
                    // own hide-on-scroll (`!widget.isHeaderHidden`), so a downward
                    // scroll takes it away with the header and an upward one brings it
                    // back. Suppressed while searching, like the bottom button.
                    Positioned(
                      right: 16,
                      bottom: messageListBottom + 16 + 44 + 8,
                      child: _ChatScrollButton(
                        visible: showScrollTopBtn,
                        icon: Icons.keyboard_arrow_up_rounded,
                        onTap: _scrollToTop,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // The composer and the drawer are drawn by the page; these keep
            // their logic, and what Flutter lays over them (guide anchors, the
            // desktop drop targets). In page coordinates: the WebView's box.
            Positioned.fill(
              child: Builder(
                builder: (context) {
                  final allSelectedHidden = _selectionCtrl.allSelectedHidden(
                    widget.state.messages,
                  );
                  final canDeleteSelected = _selectionCtrl.canDeleteSelection(
                    widget.state.messages,
                  );
                  return ChatComposerHost(
                    key: ValueKey(widget.state.session?.id),
                    channel: widget.chrome,
                    composerFocus: widget.drawerCtrl.inputFocus,
                    charId: widget.charId,
                    initialDraft: widget.state.session?.draft ?? '',
                    onDraftChanged: (text) {
                      ref
                          .read(chatProvider(widget.charId).notifier)
                          .saveDraft(text);
                    },
                    showSearchControls: widget.search.showSearch,
                    searchMatchCount: widget.search.matchCount,
                    searchCurrentIndex: widget.search.searchCurrentIndex,
                    onSearchNext: widget.search.onSearchNext,
                    onSearchPrev: widget.search.onSearchPrev,
                    isEditingMessage: isEditingMessage,
                    isSelectionMode: _selectionCtrl.isSelectionMode,
                    selectedCount: _selectionCtrl.selectedMessageIds.length,
                    allSelectedHidden: allSelectedHidden,
                    canDeleteSelected: canDeleteSelected,
                    onCancelSelection: () {
                      setState(() {
                        _selectionCtrl.clearSelection();
                      });
                    },
                    // The WebView owns the selection set, so the range
                    // buttons ask it to extend (or clear) the run; the
                    // resulting onSelectionChange updates the toolbar.
                    onSelectAbove: () {
                      _webViewStateKey.currentState?.selectMessagesAbove();
                    },
                    onSelectBelow: () {
                      _webViewStateKey.currentState?.selectMessagesBelow();
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
                      if (!await confirmMessageDeletion(
                        context,
                        ref,
                        sessionId: widget.state.session?.id,
                      )) {
                        return;
                      }
                      if (!mounted || !context.mounted) return;
                      // deleteSelected drops the selection synchronously;
                      // rebuild before awaiting so the toolbar closes with
                      // the messages instead of after the DB cleanup.
                      final pending = _selectionCtrl.deleteSelected(
                        ref,
                        widget.charId,
                        widget.state.messages,
                      );
                      if (mounted) setState(() {});
                      await pending;
                      if (mounted) setState(() {});
                    },
                    isDrawerOpen:
                        widget.drawerCtrl.drawerOpen ||
                        widget.drawerCtrl.switchingToDrawer,
                    virtualKeyboardSend: widget.virtualKeyboardSend,
                    enterToSend: widget.enterToSend,
                    canSend: () =>
                        _ensurePersonaSelected() &&
                        _ensureApiSelected() &&
                        _ensureContextFits(),
                    onSend: (text) async {
                      if (text.trim().isEmpty) return false;
                      if (!await _maybeSeedGameTime()) return false;
                      // The follow is armed by the sync dispatcher on the
                      // rising edge of the send window, which is the
                      // dispatch that appends the bubble.
                      return ref
                          .read(chatProvider(widget.charId).notifier)
                          .trySendMessage(text);
                    },
                    onSendWithGuidance: (text, guidance) async {
                      if (text.trim().isEmpty) return false;
                      if (!await _maybeSeedGameTime()) return false;
                      return ref
                          .read(chatProvider(widget.charId).notifier)
                          .trySendMessage(text, guidanceText: guidance);
                    },
                    onSendWithImages:
                        (text, guidanceText, imageDataUrls) async {
                          if (!await _maybeSeedGameTime()) return false;
                          return ref
                              .read(chatProvider(widget.charId).notifier)
                              .trySendMessage(
                                text,
                                guidanceText: guidanceText,
                                imageDataUrls: imageDataUrls,
                              );
                        },
                    isGenerating: widget.state.isGenerating,
                    isGeneratingImage: widget.state.isGeneratingImage,
                    isPostGenRunning: widget.state.isPostGenRunning,
                    onStop:
                        (widget.state.isGenerating ||
                            widget.state.isGeneratingImage ||
                            widget.state.isPostGenRunning)
                        ? () {
                            final notifier = ref.read(
                              chatProvider(widget.charId).notifier,
                            );
                            if (widget.state.isGeneratingImage &&
                                !widget.state.isGenerating) {
                              notifier.cancelImageGeneration();
                            } else {
                              notifier.abortGeneration();
                            }
                          }
                        : null,
                    // On desktop the drawer lives in the right sidebar and the
                    // bottom drawer is never rendered — the button would only
                    // animate an empty gap open, so it is left out.
                    onMagicDrawer: isDesktopLayout(context)
                        ? null
                        : () {
                            // Edit mode never survives a close: it drives the
                            // drawer's badges *and* the composer row's, and a
                            // flag left standing would greet the next open
                            // with arrows nobody asked for.
                            if (!widget.drawerCtrl.drawerOpen) {
                              ref
                                      .read(chatDrawerEditingProvider.notifier)
                                      .state =
                                  false;
                            }
                            widget.drawerCtrl.toggleDrawer(context);
                          },
                    beforeGeneration: _beforeQuickReply,
                    onImpersonate: (guidance) => ref
                        .read(chatProvider(widget.charId).notifier)
                        .impersonate(guidanceText: guidance),
                  );
                },
              ),
            ),
            // Positioned so the zero-sized host never decides the Stack's
            // size: a lone non-positioned child makes the whole chat body
            // collapse to 0x0 (and take the WebView with it) the moment the
            // drawer opens.
            if (renderDrawer)
              Positioned.fill(
                child: ChatDrawerHost(
                  channel: widget.chrome,
                  charId: widget.charId,
                  beforeGeneration: _beforeQuickReply,
                  onClose: () => widget.drawerCtrl.closeDrawer(),
                  disableEffects:
                      batterySaver && widget.drawerCtrl.isDrawerAnimating,
                  onScrollToMessage: (id) => _scrollToTargetMessage(id),
                ),
              ),
            // Guide tours point at the header through these.
            Positioned.fill(
              child: IgnorePointer(
                child: ValueListenableBuilder<ChromeLayoutReport>(
                  valueListenable: widget.chrome.layout,
                  builder: (context, layout, _) => Stack(
                    children: [
                      chromeAnchor(GuideIds.chatHeader, layout.headerBlock),
                      chromeAnchor(GuideIds.chatSearch, layout.searchButton),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
