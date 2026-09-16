import 'package:flutter/foundation.dart';

/// Where the glass blur of the chat chrome (header pill, input pill, the
/// circle buttons beside it) is actually produced.
///
/// A Flutter `BackdropFilter` blurs what is already drawn into the Flutter
/// frame. Whether the chat `InAppWebView` is part of that frame depends on how
/// each platform embeds it, and that is the whole decision here:
///
///  * **Windows** — `flutter_inappwebview_windows` never puts a WebView2 child
///    window over the Flutter surface. It drives WebView2 off-screen, captures
///    its frames and hands them to the engine as an external texture that the
///    plugin draws with a `Texture` widget. The web content is therefore an
///    ordinary layer of the Flutter frame and a `BackdropFilter` above it
///    samples it like any other pixels.
///  * **iOS** — the embedder implements backdrop blur for platform views: when
///    a `BackdropFilter` overlaps a `UiKitView`, it copies the `gaussianBlur`
///    `CAFilter` out of a `UIVisualEffectView` and installs it on the platform
///    view's clipping layer, so UIKit blurs the WKWebView for us.
///  * **Android** — nothing blurs a platform view under hybrid composition,
///    where Flutter content above the WebView is drawn into a separate overlay
///    surface. Under texture layer hybrid composition (TLHC) the WebView is
///    drawn into an `ImageReader` surface that Flutter composites as a texture
///    layer inside the frame, which a `BackdropFilter` can sample — the same
///    reason `video_player`'s texture mode can be blurred and its platform-view
///    mode cannot. Which one we get is [chatWebViewUsesHybridComposition].
///  * **macOS / Linux** — an `NSView` platform view with no embedder support
///    (and no WebView at all on Linux), so the in-WebView CSS strips stay.
///
/// Where this returns false the chrome drops its own blur pass and the blur is
/// mirrored into the WebView as fixed `backdrop-filter` strips positioned over
/// the bridge — correct, but two layers that have to be kept in sync, and they
/// visibly lag the widget whenever the chrome moves.
///
/// [platform] is for tests; production callers pass nothing and get
/// [defaultTargetPlatform].
bool chatWebViewBlurIsFlutterSide([TargetPlatform? platform]) {
  if (kChatWebViewForceCssBlur) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.iOS => true,
    TargetPlatform.android => !chatWebViewUsesHybridComposition(),
    _ => false,
  };
}

/// Value for `InAppWebViewSettings.useHybridComposition`, read only on Android.
///
/// False puts the chat WebView on texture layer hybrid composition (the plugin
/// switches from `initExpensiveAndroidView` to `initSurfaceAndroidView`), which
/// is what makes [chatWebViewBlurIsFlutterSide] true there. The known costs:
/// TLHC cannot host a `SurfaceView` (fullscreen HTML5 video would render at the
/// wrong place — the chat page plays none), it copies the WebView's frame into
/// a texture, and the texture can trail the Flutter frame by one frame. The
/// trailing frame moves nothing on screen: the blurred *content* is one frame
/// old, the blurred *rect* is exactly the widget's, which is the opposite of
/// the mirrored-strip lag it replaces.
bool chatWebViewUsesHybridComposition() => kChatWebViewForceHybridComposition;

/// `--dart-define=CHAT_WEBVIEW_CSS_BLUR=true` puts every platform back on the
/// mirrored CSS strips, for comparing the two against each other in one build.
const bool kChatWebViewForceCssBlur = bool.fromEnvironment(
  'CHAT_WEBVIEW_CSS_BLUR',
);

/// `--dart-define=CHAT_WEBVIEW_HYBRID_COMPOSITION=true` puts Android back on
/// hybrid composition — and therefore back on the CSS strips, since nothing can
/// sample a platform view there.
const bool kChatWebViewForceHybridComposition = bool.fromEnvironment(
  'CHAT_WEBVIEW_HYBRID_COMPOSITION',
);
