import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

final chatWebViewKeepAlive = InAppWebViewKeepAlive();

/// Mobile preloads the chat WebView at app startup and reuses it when a chat
/// opens. Desktop creates the WebView when the chat opens, so there is no
/// preloaded instance to attach to. Enabling keep-alive on Windows was
/// attempted but caused silent crashes, so it remains disabled. On Linux the
/// WPE plugin names the view's method channel after its numeric id while the
/// Dart side listens on the keep-alive id, so a keep-alive view never gets its
/// load or JS handler callbacks.
InAppWebViewKeepAlive? chatWebViewKeepAliveForPlatform() {
  if (defaultTargetPlatform == TargetPlatform.windows) return null;
  if (defaultTargetPlatform == TargetPlatform.linux) return null;
  return chatWebViewKeepAlive;
}
