import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chat_background.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/debug/perf_debug.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../bridge/chat_bridge_controller.dart';
import '../bridge/chat_bridge_registry.dart';
import '../bridge/chat_webview_bridge_host.dart';
import '../bridge/chat_webview_environment.dart';
import '../bridge/chat_webview_keep_alive.dart';
import '../bridge/chat_webview_settings.dart';
import '../../settings/app_settings_provider.dart';
import 'chat_webview_callbacks.dart';
import 'chat_webview_ext_block_callbacks.dart';
import 'chat_webview_trackpad_scroll.dart';
import 'message_scripts_prompt_sheet.dart';
import 'webview_callbacks.dart';

/// `InAppWebView` with chat-specific settings and bridge wiring.
///
/// On Windows, native view creation is asynchronous and the upstream platform
/// widget is unsafe if disposed before creation returns. Delay mounting it for
/// one Flutter frame, so a route dismissed immediately never starts a native
/// creation that could later callback into a disposed widget.
class ChatWebViewSurface extends ConsumerStatefulWidget {
  const ChatWebViewSurface({
    super.key,
    required this.bridgeHost,
    required this.charId,
    required this.sessionId,
    required this.messageActions,
    required this.editActions,
    required this.imageGenActions,
    required this.scrollActions,
    required this.miscActions,
    required this.isCurrentSession,
    required this.lifecycleEpoch,
    required this.isActive,
    required this.sessionSwitching,
    required this.refreshPanel,
    required this.bgImageBytes,
    required this.bgBlur,
    required this.bgDim,
    required this.chatBgMode,
    required this.chatBgColor,
    required this.chatBgAvatarPath,
    required this.bottomInset,
    required this.onBridgeReady,
    required this.onInitWebView,
    required this.onPageProcessGone,
    this.rebuildGeneration = 0,
  });

  final ChatWebViewBridgeHost bridgeHost;
  final String charId;
  final String? sessionId;
  final MessageActionsCallbacks messageActions;
  final EditActionsCallbacks editActions;
  final ImageGenCallbacks imageGenActions;
  final ScrollCallbacks scrollActions;
  final MiscCallbacks miscActions;

  /// Prevents an async native callback from installing bridge handlers for a
  /// session that has since been replaced.
  final bool Function(String? sessionId) isCurrentSession;
  final int lifecycleEpoch;
  final bool Function(int epoch) isActive;
  final bool sessionSwitching;
  final Future<void> Function(String sessionId, String messageId) refreshPanel;
  final Uint8List? bgImageBytes;
  final double bgBlur;
  final double bgDim;

  /// Chat-area background source: inherit, color, avatar, or custom.
  final String chatBgMode;
  final Color? chatBgColor;
  final String? chatBgAvatarPath;
  final double bottomInset;

  /// Called after the surface has safely wired the JavaScript bridge.
  final void Function(ChatBridgeController bridge) onBridgeReady;

  /// Starts the parent's idempotent WebView initialization.
  final Future<void> Function() onInitWebView;

  /// The page behind this surface died — Android killed the render process,
  /// or iOS terminated the web content process. The parent owns what happens
  /// next; the surface only reports it.
  final VoidCallback onPageProcessGone;

  /// Bumped by the parent to demand a brand new native WebView. The keep-alive
  /// instance is shared by every chat, so a dead one has to be disposed before
  /// the replacement is attached — otherwise the new widget re-attaches the
  /// same corpse.
  final int rebuildGeneration;

  @override
  ConsumerState<ChatWebViewSurface> createState() => _ChatWebViewSurfaceState();
}

class _ChatWebViewSurfaceState extends ConsumerState<ChatWebViewSurface> {
  bool _mountNativeView = !Platform.isWindows;

  /// Built once per surface. [InAppWebViewSettings] is only read when the
  /// platform view is first created, but every rebuild used to allocate a
  /// fresh one — along with the WebViewAssetLoader/AssetsPathHandler it
  /// carries, which register with the plugin and are never released.
  late final InAppWebViewSettings _webViewSettings = chatWebViewInAppSettings();

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _mountNativeView = true);
      });
    }
  }

  @override
  void didUpdateWidget(ChatWebViewSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.rebuildGeneration != oldWidget.rebuildGeneration) {
      unawaited(_rebuildNativeView());
    }
  }

  /// Replaces the native WebView after its page died.
  ///
  /// The view is unmounted for a frame first, and the keep-alive instance
  /// disposed while nothing is attached to it: on mobile every chat shares one
  /// preloaded WebView, so remounting without disposing hands the replacement
  /// widget the same dead native view and nothing changes. Disposing frees the
  /// keep-alive id, and the remount below creates a fresh WebView under it.
  Future<void> _rebuildNativeView() async {
    if (!mounted) return;
    setState(() => _mountNativeView = false);
    final keepAlive = chatWebViewKeepAliveForPlatform();
    if (keepAlive != null) {
      try {
        await InAppWebViewController.disposeKeepAlive(keepAlive);
      } catch (e) {
        debugPrint('[ChatWebView] disposing the keep-alive failed: $e');
      }
    }
    // One frame with nothing attached, so the platform view is really gone
    // before its replacement asks to be created.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    setState(() => _mountNativeView = true);
  }

  Widget _background(BuildContext context) {
    return ChatBackground(
      mode: widget.chatBgMode,
      color: widget.chatBgColor,
      avatarPath: widget.chatBgAvatarPath,
      imageBytes: widget.bgImageBytes,
      blur: widget.bgBlur,
      dim: widget.bgDim,
    );
  }

  bool _callbackIsActive(int epoch) {
    return widget.isActive(epoch) && widget.isCurrentSession(widget.sessionId);
  }

  Future<void> _onWebViewCreated(InAppWebViewController controller) async {
    final epoch = widget.lifecycleEpoch;
    if (!_callbackIsActive(epoch)) return;
    PerfDebug.chatWebViewSurfaceCreated();
    final jsBridgeService = await widget.bridgeHost.buildJsBridgeService();
    if (!_callbackIsActive(epoch) || jsBridgeService == null) return;
    final bridge = ChatBridgeController(controller, jsBridgeService);
    final allowMessageScripts =
        ref.read(appSettingsProvider).value?.allowMessageScripts ?? false;
    await bridge.evalJs(
      'window.bridge?.setAllowMessageScripts($allowMessageScripts)',
    );
    if (!_callbackIsActive(epoch)) return;
    widget.onBridgeReady(bridge);
    PerfDebug.chatWebViewBridgeReady();

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
    bridge.onChangeGreeting = callbacks.onChangeGreeting;
    bridge.onHeaderScroll = callbacks.onHeaderScroll;
    bridge.onScrollToBottomVisibility = callbacks.onScrollToBottomVisibility;
    bridge.onRegenerate = callbacks.onRegenerate;
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
    bridge.onImgEnableRetry = callbacks.onImgEnableRetry;
    bridge.onImgFind = callbacks.onImgFind;
    bridge.onImgRegen = callbacks.onImgRegen;
    bridge.onImgOptions = callbacks.onImgOptions;
    bridge.onImgVariant = callbacks.onImgVariant;
    bridge.onImgCancel = callbacks.onImgCancel;
    bridge.onStop = callbacks.onStop;
    bridge.onLinkClick = callbacks.onLinkClick;
    bridge.onLoadMore = callbacks.onLoadMore;
    bridge.onMessageScriptBlocked = () {
      if (_callbackIsActive(epoch)) {
        // The callback owns the bridge lifecycle guard above.
        // ignore: use_build_context_synchronously
        unawaited(maybeShowMessageScriptsPrompt(context, ref));
      }
    };

    if (!_callbackIsActive(epoch) || !mounted) return;
    final extBlocks = ChatWebViewExtBlockCallbacks(
      ref: ref,
      charId: widget.charId,
      sessionId: widget.sessionId,
      // The mounted guard above protects this long-lived callback context.
      // ignore: use_build_context_synchronously
      context: context,
      isMounted: () => _callbackIsActive(epoch),
      refreshPanel: widget.refreshPanel,
    );
    bridge.onExtBlocksRunAll = extBlocks.onRunAll();
    bridge.onExtBlockStop = extBlocks.onStop();
    bridge.onExtBlockRegen = extBlocks.onRegen();
    bridge.onExtBlockRegenImage = extBlocks.onRegenImage();
    bridge.onExtBlockEdit = extBlocks.onEdit();
    bridge.onExtBlockDelete = extBlocks.onDelete();

    final isAlive = await controller.isLoading() == false;
    if (isAlive && _callbackIsActive(epoch)) {
      await widget.onInitWebView();
    }
  }

  Future<void> _onLoadStop(InAppWebViewController controller, Uri? url) async {
    final epoch = widget.lifecycleEpoch;
    if (!_callbackIsActive(epoch)) return;
    PerfDebug.chatWebViewLoadStopped();
    await ref
        .read(chatBridgeRegistryProvider(widget.charId))
        ?.evalJs(
          'window.bridge?.setAllowMessageScripts('
          '${ref.read(appSettingsProvider).value?.allowMessageScripts ?? false})',
        );
    if (_callbackIsActive(epoch)) {
      await widget.onInitWebView();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AppSettings>>(appSettingsProvider, (previous, next) {
      final oldValue = previous?.value?.allowMessageScripts ?? false;
      final newValue = next.value?.allowMessageScripts ?? false;
      if (oldValue != newValue) {
        ref
            .read(chatBridgeRegistryProvider(widget.charId))
            ?.evalJs('window.bridge?.setAllowMessageScripts($newValue)');
      }
    });
    return Stack(
      children: [
        Positioned.fill(child: _background(context)),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: widget.sessionSwitching,
            // Windows touchpad panning is forwarded by this wrapper. Keeping it
            // below IgnorePointer freezes native interaction during a switch.
            child: _mountNativeView
                ? ChatWebViewTrackpadScroll(
                    charId: widget.charId,
                    child: InAppWebView(
                      key: ValueKey<int>(widget.rebuildGeneration),
                      webViewEnvironment: chatWebViewEnvironment,
                      keepAlive: chatWebViewKeepAliveForPlatform(),
                      initialFile: chatWebViewInitialFile(),
                      initialUrlRequest: chatWebViewInitialUrlRequest(),
                      initialSettings: _webViewSettings,
                      onWebViewCreated: _onWebViewCreated,
                      onLoadStop: _onLoadStop,
                      // Android 26+. Until this was handled, a killed render
                      // process left a blank page the app kept talking to.
                      onRenderProcessGone: (controller, detail) {
                        debugPrint(
                          '[ChatWebView] render process gone '
                          '(didCrash: ${detail.didCrash})',
                        );
                        if (_callbackIsActive(widget.lifecycleEpoch)) {
                          widget.onPageProcessGone();
                        }
                      },
                      onWebContentProcessDidTerminate: (controller) {
                        debugPrint(
                          '[ChatWebView] web content process terminated',
                        );
                        if (_callbackIsActive(widget.lifecycleEpoch)) {
                          widget.onPageProcessGone();
                        }
                      },
                      shouldOverrideUrlLoading: (controller, request) async {
                        return chatWebViewNavigationPolicy(request.request.url);
                      },
                    ),
                  )
                : const SizedBox.expand(),
          ),
        ),
        if (widget.sessionSwitching)
          Positioned.fill(child: IgnorePointer(child: _background(context))),
        if (widget.sessionSwitching) const Center(child: GlazeSpinner()),
        if (widget.bottomInset > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.02),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
