import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../bridge/chat_webview_environment.dart';
import '../bridge/chat_webview_keep_alive.dart';
import '../bridge/chat_webview_settings.dart';

class ChatWebViewPreloader extends StatefulWidget {
  final Widget child;
  const ChatWebViewPreloader({super.key, required this.child});
  @override
  State<ChatWebViewPreloader> createState() => _ChatWebViewPreloaderState();
}

class _ChatWebViewPreloaderState extends State<ChatWebViewPreloader> {
  bool _preloaded = false;

  /// Same reasoning as the chat surface: allocate the settings once instead
  /// of on every rebuild of the preloader.
  late final InAppWebViewSettings _webViewSettings = chatWebViewInAppSettings();

  /// The preloaded page's render process died before any chat attached to it.
  ///
  /// Android kills the render process under memory pressure, and the WebView
  /// preloaded at startup is an ordinary victim. The preloader used to keep
  /// that corpse in the shared keep-alive: the first chat to open re-attached
  /// to a page that no longer existed, and the reader got a blank chat whose
  /// bridge never came up. Drop the dead keep-alive instead, so the first chat
  /// builds a fresh native WebView, and stop preloading for this launch — a
  /// process that died once under memory pressure is not worth preloading a
  /// replacement of, and remounting here could race a chat that is already
  /// attaching.
  ///
  /// This covers the preload window only. Once `onLoadStop` retires the
  /// preloader's WebView there is no native view listening for death, which is
  /// why the surface's own init handshake has to bound its reads and rebuild.
  void _handlePreloadProcessGone() {
    if (!mounted || _preloaded) return;
    debugPrint(
      '[ChatWebView] preload render process gone; dropping the preload '
      'keep-alive so the first chat builds a fresh WebView',
    );
    // Unmount the dead platform view first, then dispose the keep-alive on the
    // next frame — the same order the chat surface uses when it replaces a
    // dead view.
    setState(() => _preloaded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await InAppWebViewController.disposeKeepAlive(chatWebViewKeepAlive);
      } catch (e) {
        debugPrint('[ChatWebView] disposing the preload keep-alive failed: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Skip webview preloading on Windows and Linux (no InAppWebView
    // implementation on either) and in widget tests. In tests the InAppWebView platform channel isn't
    // registered, so building it throws (`InAppWebViewPlatform.instance !=
    // null`). The test runner exposes FLUTTER_TEST as a *runtime* env var, so we
    // must read Platform.environment — `bool.fromEnvironment` is compile-time
    // (--dart-define) and stays false under `flutter test`.
    final isTest = Platform.environment.containsKey('FLUTTER_TEST');
    final shouldPreload = !isTest && !Platform.isWindows && !Platform.isLinux;
    return Stack(
      children: [
        widget.child,
        if (shouldPreload && !_preloaded)
          IgnorePointer(
            child: Opacity(
              opacity: 0,
              child: SizedBox(
                width: 1,
                height: 1,
                child: InAppWebView(
                  keepAlive: chatWebViewKeepAlive,
                  initialFile: chatWebViewInitialFile(),
                  initialUrlRequest: chatWebViewInitialUrlRequest(),
                  initialSettings: _webViewSettings,
                  onLoadStop: (_, _) {
                    if (mounted) setState(() => _preloaded = true);
                  },
                  onRenderProcessGone: (_, detail) {
                    debugPrint(
                      '[ChatWebView] preload render process gone '
                      '(didCrash: ${detail.didCrash})',
                    );
                    _handlePreloadProcessGone();
                  },
                  onWebContentProcessDidTerminate: (_) {
                    debugPrint(
                      '[ChatWebView] preload web content process terminated',
                    );
                    _handlePreloadProcessGone();
                  },
                  shouldOverrideUrlLoading: (controller, request) async {
                    return chatWebViewNavigationPolicy(request.request.url);
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}
