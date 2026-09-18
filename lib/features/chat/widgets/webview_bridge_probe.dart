import 'dart:async';

/// Probes whether the page's JS bridge is up, bounded by [timeout].
///
/// [read] is one bridge read — in production, the WebView's
/// `evaluateJavascript` for the "is `window.bridge` defined" expression.
///
/// The bound is the whole point. The chat page is kept alive across chats, and
/// the OS can kill its render process while no chat is mounted (Android does
/// this under memory pressure to the shared keep-alive WebView). The dead page
/// is still attached and still accepts calls, but it never answers them. A
/// plain `await` on that read parks the bridge handshake forever, and it does
/// so *after* the init future is claimed — so the `_kickInitWhenReady` safety
/// net has already backed off, the ready-wait and init timeouts are never
/// reached, and no rebuild is ever requested. The reader is left with a blank
/// chat that only reopening can fix.
///
/// A [TimeoutException] out of here is the signal the init path already knows
/// how to act on: a failed attempt that requests a rebuild of the native view.
Future<bool> probeWebViewJsBridge(
  Future<Object?> Function() read, {
  required Duration timeout,
}) async {
  final result = await read().timeout(timeout);
  return result == true;
}
