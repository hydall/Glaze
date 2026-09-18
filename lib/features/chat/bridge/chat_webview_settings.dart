import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'chat_webview_blur_mode.dart';

/// Android reserved domain for [WebViewAssetLoader] (flutter_inappwebview default).
const String kChatWebViewAndroidAssetDomain = 'appassets.androidplatform.net';

/// HTTPS entry for the chat WebView on Android. ES module imports require a
/// proper origin; `initialFile` / `file://` leaves modules on an opaque origin.
const String kChatWebViewAndroidAssetUrl =
    'https://$kChatWebViewAndroidAssetDomain/assets/flutter_assets/assets/chat_webview/index.html';

String? _chatWebViewAndroidFileRoot;

String? get chatWebViewAndroidFileRoot => _chatWebViewAndroidFileRoot;

void setChatWebViewAndroidFileRoot(String root) {
  _chatWebViewAndroidFileRoot = root;
}

/// Value for [InAppWebViewSettings.transparentBackground].
///
/// On Windows, `flutter_inappwebview_windows` 0.6.x inverts this flag in native
/// code (true leaves an opaque white WebView2 surface). Pass `false` there so
/// WebView2 gets a transparent default background and the Flutter stack behind
/// the chat WebView is visible. See flutter_inappwebview issue #2735.
bool chatWebViewTransparentBackground() {
  if (defaultTargetPlatform == TargetPlatform.windows) return false;
  return true;
}

/// Value for [InAppWebViewSettings.allowFileAccessFromFileURLs].
///
/// Windows/WebView2 loads Flutter assets through `file://` URLs, and ES module
/// imports need access to sibling module files in `assets/chat_webview/`.
/// Android uses [WebViewAssetLoader] instead. Universal file URL access stays
/// disabled on every platform.
bool chatWebViewAllowFileAccessFromFileUrls() {
  if (defaultTargetPlatform == TargetPlatform.windows) return true;
  return false;
}

/// Whether the chat WebView should load bundled assets through Android's
/// [WebViewAssetLoader] (HTTPS app-assets origin) instead of `initialFile`.
bool chatWebViewUsesAndroidAssetLoader() {
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}

/// HTTPS URL for the chat WebView entry page on Android, or `null` elsewhere.
String? chatWebViewAndroidAssetUrl() {
  if (!chatWebViewUsesAndroidAssetLoader()) return null;
  return kChatWebViewAndroidAssetUrl;
}

/// Android [WebViewAssetLoader] for bundled chat assets, or `null` elsewhere.
/// One loader for the whole app. The chat WebView is kept alive and reused
/// ([chatWebViewKeepAliveForPlatform]), and the plugin only parses
/// `initialSettings` when it actually builds a new native WebView — a
/// keep-alive reuse skips `FlutterWebView` entirely. A per-mount handler would
/// therefore register a MethodChannel that the native side never calls, and
/// nothing disposes it.
WebViewAssetLoader? _sharedChatAssetLoader;

WebViewAssetLoader? chatWebViewAssetLoader() {
  if (!chatWebViewUsesAndroidAssetLoader()) return null;
  // Bundled chat assets only. Local Glaze files are served by the loopback
  // HTTP server started in [initChatWebViewEnvironment] — not
  // [InternalStoragePathHandler], which crashes on 6.1.5 (#1980 / #2451).
  return _sharedChatAssetLoader ??= WebViewAssetLoader(
    pathHandlers: [AssetsPathHandler(path: '/assets/')],
  );
}

/// Android chat HTML loads over HTTPS (asset loader) while local images are
/// served from `http://127.0.0.1` — allow compatible mixed content (images).
MixedContentMode chatWebViewMixedContentMode() {
  if (chatWebViewUsesAndroidAssetLoader()) {
    return MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE;
  }
  return MixedContentMode.MIXED_CONTENT_NEVER_ALLOW;
}

/// Shared [InAppWebViewSettings] for the chat WebView and its preloader.
InAppWebViewSettings chatWebViewInAppSettings({bool isInspectable = true}) {
  return InAppWebViewSettings(
    javaScriptEnabled: true,
    domStorageEnabled: true,
    transparentBackground: chatWebViewTransparentBackground(),
    isInspectable: isInspectable,
    // Android composition mode. See [chatWebViewUsesHybridComposition] — true
    // (the default) keeps the WebView a real view in the Android hierarchy;
    // false hands it to Flutter as a texture layer, which is what would let the
    // chat chrome blur it with an ordinary BackdropFilter.
    useHybridComposition: chatWebViewUsesHybridComposition(),
    cacheEnabled: true,
    useWideViewPort: true,
    loadWithOverviewMode: true,
    allowFileAccess: true,
    allowContentAccess: true,
    allowFileAccessFromFileURLs: chatWebViewAllowFileAccessFromFileUrls(),
    allowUniversalAccessFromFileURLs: false,
    mixedContentMode: chatWebViewMixedContentMode(),
    useShouldOverrideUrlLoading: true,
    webViewAssetLoader: chatWebViewAssetLoader(),
    // The page is a full-screen chat whose only scroll is the in-page
    // #chat-container. The document itself is pinned in CSS (`html, body` are
    // `position: fixed; overflow: hidden`), so it has no scroll range on either
    // axis and nothing native is left to suppress; this only stops the
    // overscroll glow/bounce from dragging the fixed Flutter-glass blur strips
    // out from under the Flutter chrome.
    //
    // Neither `disableHorizontalScroll` nor `disableVerticalScroll` may be set
    // here. On Android the plugin implements both by rewriting the touch
    // stream: with a single axis disabled it calls `event.setLocation()` on
    // every ACTION_MOVE/UP/CANCEL and pins that axis to its ACTION_DOWN value,
    // so the page sees a touch that never moves along it. Pinning X killed the
    // message swipe gesture (its dx was always 0, so the axis lock read every
    // drag as a vertical scroll) along with horizontal scrolling of wide code
    // blocks and tables; pinning Y would take the container's own touch
    // scrolling down with it.
    disallowOverScroll: true,
  );
}
