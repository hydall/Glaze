import 'package:flutter/foundation.dart';

/// Where the glass blur of the chat chrome (header pill, input pill, the
/// circle buttons beside it) is actually produced.
///
/// The default everywhere is the mirrored path: the chrome drops its own blur
/// pass and the blur is reproduced by `backdrop-filter` strips *inside* the
/// WebView, positioned from rects Flutter measures and pushes over the bridge
/// (see [ChatOverlayBlurRegion] and `setOverlayBlurRegions`).
///
/// The alternative is a Flutter `BackdropFilter` that samples the WebView
/// directly. That works only where the WebView is part of the Flutter frame:
///
///  * **Windows** — `flutter_inappwebview_windows` drives WebView2 off-screen
///    and hands its frames to the engine as an external texture drawn with a
///    `Texture` widget, so the web content is an ordinary layer of the frame.
///  * **iOS** — the embedder implements backdrop blur for platform views: a
///    `BackdropFilter` over a `UiKitView` installs a `gaussianBlur` CAFilter on
///    the platform view's clipping layer.
///  * **Android** — only under texture layer hybrid composition, which is why
///    the opt-in also turns [chatWebViewUsesHybridComposition] off.
///  * **macOS / Linux** — an unsampled `NSView` platform view (and no WebView
///    at all on Linux), so it cannot work there at all.
///
/// It is off by default because of what it costs while the reader scrolls. The
/// backdrop under the glass is then new pixels on every frame, so the blur can
/// never be reused: on Windows that is a render-pass break and a blur pass per
/// strip per frame, and on Android it also puts the WebView on a texture-layer
/// copy of every frame that hybrid composition does not pay for.
///
/// `--dart-define=CHAT_WEBVIEW_FLUTTER_BLUR=true` opts back into it, for
/// comparing the two paths against each other in one build.
const bool kChatWebViewFlutterBlur = bool.fromEnvironment(
  'CHAT_WEBVIEW_FLUTTER_BLUR',
);

/// Whether the chrome blurs the WebView with its own `BackdropFilter` rather
/// than having that blur mirrored into the page.
///
/// [platform] is for tests; production callers pass nothing and get
/// [defaultTargetPlatform].
bool chatWebViewBlurIsFlutterSide([TargetPlatform? platform]) {
  if (!kChatWebViewFlutterBlur) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.iOS => true,
    TargetPlatform.android => !chatWebViewUsesHybridComposition(),
    _ => false,
  };
}

/// Value for `InAppWebViewSettings.useHybridComposition`, read only on Android.
///
/// True (the default) keeps the WebView on hybrid composition: it stays a real
/// view in the Android hierarchy and Flutter content above it goes to an
/// overlay surface. Nothing in the Flutter frame can sample it — which is
/// exactly why the blur is mirrored into the page instead.
///
/// The opt-in flips it to texture layer hybrid composition, where the WebView
/// is drawn into an `ImageReader` surface that Flutter composites as a texture
/// layer and a `BackdropFilter` can therefore sample. That copy is per frame,
/// the texture can trail the Flutter frame by one, and TLHC cannot host a
/// `SurfaceView` — fullscreen HTML5 video would render in the wrong place, of
/// which the chat page plays none.
bool chatWebViewUsesHybridComposition() => !kChatWebViewFlutterBlur;
