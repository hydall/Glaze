import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/bridge/chat_webview_environment.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_webview_keep_alive.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_webview_settings.dart';

void main() {
  group('chat WebView keepAlive policy', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('does not attach preload keepAlive on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      expect(chatWebViewKeepAliveForPlatform(), isNull);
    });

    test('reuses app-start preload keepAlive on mobile', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(chatWebViewKeepAliveForPlatform(), same(chatWebViewKeepAlive));
    });
  });

  group('chat WebView file access policy', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      setChatWebViewLocalFileBaseUrlForTesting(null);
    });

    test('allows bundled asset module imports on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      expect(chatWebViewAllowFileAccessFromFileUrls(), isTrue);
    });

    test('keeps file URL reads disabled on mobile', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(chatWebViewAllowFileAccessFromFileUrls(), isFalse);
    });

    test('fails closed on desktop platforms without a local-file server', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      expect(
        chatWebViewResolveLocalFileUrl(
          '${Directory.current.path}${Platform.pathSeparator}avatars'
          '${Platform.pathSeparator}avatar.png',
        ),
        isNull,
      );
    });
  });

  group('chat WebView Android asset loader', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      setChatWebViewLocalFileBaseUrlForTesting(null);
      setChatWebViewAndroidFileRoot('');
    });

    test('loads bundled chat assets over HTTPS on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(chatWebViewUsesAndroidAssetLoader(), isTrue);
      expect(
        chatWebViewAndroidAssetUrl(),
        contains(kChatWebViewAndroidAssetDomain),
      );
      expect(chatWebViewInitialFile(), isNull);
      expect(
        chatWebViewInitialUrlRequest()?.url.toString(),
        kChatWebViewAndroidAssetUrl,
      );
    });

    test('allows loopback image URLs via mixed content compatibility mode', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(
        chatWebViewMixedContentMode(),
        MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
      );
    });

    test('maps Android Glaze files to loopback HTTP URLs', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      setChatWebViewAndroidFileRoot('/data/user/0/com.hydall.glaze/Glaze');
      setChatWebViewLocalFileBaseUrlForTesting(
        WebUri('http://127.0.0.1:42424/'),
      );

      final resolved = chatWebViewResolveLocalFileUrl(
        '/data/user/0/com.hydall.glaze/Glaze/avatars/char.png',
      );
      expect(
        resolved,
        startsWith('http://127.0.0.1:42424/__glaze_file__?path='),
      );
      expect(resolved, contains('avatars'));
      expect(
        chatWebViewResolveLocalFileUrl('/data/user/0/com.other/app/avatar.png'),
        isNull,
      );
      expect(chatWebViewResolveLocalFileUrl('relative/avatar.png'), isNull);
    });

    test('does not use Android asset loader on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      expect(chatWebViewUsesAndroidAssetLoader(), isFalse);
      expect(chatWebViewAndroidAssetUrl(), isNull);
      expect(chatWebViewInitialFile(), 'assets/chat_webview/index.html');
      expect(chatWebViewInitialUrlRequest(), isNull);
      expect(
        chatWebViewMixedContentMode(),
        MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      );
    });
  });

  group('chat WebView iOS loopback bundle server', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      setChatWebViewAssetBaseUrlForTesting(null);
      setChatWebViewLocalFileBaseUrlForTesting(null);
    });

    test('reuses the preload keepAlive on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      expect(chatWebViewKeepAliveForPlatform(), same(chatWebViewKeepAlive));
    });

    test('keeps universal file URL reads disabled on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      // iOS serves assets over loopback HTTP, so it never needs file:// reads.
      expect(chatWebViewAllowFileAccessFromFileUrls(), isFalse);
      expect(chatWebViewUsesAndroidAssetLoader(), isFalse);
    });

    test('falls back to bundled file:// before the bundle server starts', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      // No asset base URL yet (init not run): the WebView loads the bundled
      // index.html via initialFile so the page is never blank.
      expect(chatWebViewInitialFile(), 'assets/chat_webview/index.html');
      expect(chatWebViewInitialUrlRequest(), isNull);
    });

    test('loads index.html over loopback once the bundle server is up', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      setChatWebViewAssetBaseUrlForTesting(WebUri('http://127.0.0.1:51234/'));

      // initialFile is suppressed; the page loads from the http origin so ES
      // module imports resolve (the root cause of the blank iOS WebView).
      expect(chatWebViewInitialFile(), isNull);
      expect(
        chatWebViewInitialUrlRequest()?.url.toString(),
        'http://127.0.0.1:51234/index.html',
      );
    });

    test('allows the loopback bootstrap navigation and blocks others', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      setChatWebViewAssetBaseUrlForTesting(WebUri('http://127.0.0.1:51234/'));

      expect(
        chatWebViewNavigationPolicy(
          WebUri('http://127.0.0.1:51234/index.html'),
        ),
        NavigationActionPolicy.ALLOW,
      );
      expect(
        chatWebViewNavigationPolicy(WebUri('https://example.com/')),
        NavigationActionPolicy.CANCEL,
      );
    });

    test('allows the loopback bootstrap navigation on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      setChatWebViewAssetBaseUrlForTesting(WebUri('http://127.0.0.1:51234/'));

      expect(
        chatWebViewNavigationPolicy(
          WebUri('http://127.0.0.1:51234/index.html'),
        ),
        NavigationActionPolicy.ALLOW,
      );
      expect(
        chatWebViewNavigationPolicy(
          WebUri('http://127.0.0.1:51234/bridge/index.js'),
        ),
        NavigationActionPolicy.CANCEL,
      );
    });
  });
}
