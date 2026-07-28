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

  @override
  Widget build(BuildContext context) {
    // Skip webview preloading on Windows (no InAppWebView implementation) and
    // in widget tests. In tests the InAppWebView platform channel isn't
    // registered, so building it throws (`InAppWebViewPlatform.instance !=
    // null`). The test runner exposes FLUTTER_TEST as a *runtime* env var, so we
    // must read Platform.environment — `bool.fromEnvironment` is compile-time
    // (--dart-define) and stays false under `flutter test`.
    final isTest = Platform.environment.containsKey('FLUTTER_TEST');
    final shouldPreload = !isTest && !Platform.isWindows;
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
                  initialSettings: chatWebViewInAppSettings(),
                  onLoadStop: (_, _) {
                    if (mounted) setState(() => _preloaded = true);
                  },
                  shouldOverrideUrlLoading: (controller, request) async {
                    return NavigationActionPolicy.CANCEL;
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}
