import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

final chatWebViewKeepAlive = InAppWebViewKeepAlive();

/// Mobile preloads the chat WebView at app startup and reuses it when a chat
/// opens. Desktop creates the WebView when the chat opens, so there is no
/// preloaded instance to attach to. Enabling keep-alive on Windows was
/// attempted but caused silent crashes, so it remains disabled.
InAppWebViewKeepAlive? chatWebViewKeepAliveForPlatform() {
  if (defaultTargetPlatform == TargetPlatform.windows) return null;
  return chatWebViewKeepAlive;
}
