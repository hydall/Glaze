import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The initializer runs against a live WebView, so these assert on the order
/// its source issues bridge calls in — the same approach as
/// `chat_webview_memory_initialization_test.dart`. What matters here is
/// *when* each call happens relative to the first paint, and that is not
/// observable from anything the initializer returns.
void main() {
  late final String source = File(
    'lib/features/chat/widgets/chat_webview_initializer.dart',
  ).readAsStringSync();
  late final int runStart = source.indexOf('Future<void> run() async');
  int after(String needle) {
    final index = source.indexOf(needle, runStart);
    expect(index, isNonNegative, reason: 'not found in run(): $needle');
    return index;
  }

  test('a bubble left over from a finished run is retired before the paint', () {
    // The page is kept alive across chats and `setMessages` carries a typing
    // bubble across on purpose. A run that ended while its chat was closed
    // never got its falling edge, so the bubble is still in the page — carried
    // into the reopened chat it is a reply on its way that landed minutes ago,
    // and nothing later in the same session takes it back down.
    final retire = after('bridge.retireTypingPlaceholder()');
    final paint = after('await bridge.setMessages(');
    expect(retire, lessThan(paint));
  });

  test('the retire is guarded on nothing being in flight', () {
    // Reopening a chat whose run is *still* going must carry the bubble: it is
    // the node the reply is streaming into. The page cannot tell that bubble
    // from a leftover, so the guard is the whole of what keeps them apart.
    final guard = after('if (!input.isGenerating && !input.isSendPending) {');
    final retire = after('bridge.retireTypingPlaceholder()');
    expect(guard, lessThan(retire));
    expect(retire - guard, lessThan(120), reason: 'guard is not the retire\'s');
  });

  test('the run flags reach the page before the first paint', () {
    // The elapsed clock runs off these two, so a chat reopened mid-run should
    // find it already going instead of a bubble with no clock until whatever
    // rebuild comes next. The send window is the half that was missing: only
    // the Dart-side mirror was set here, never the page's own flag.
    final generating = after('window.bridge.setGenerating(');
    final sendPending = after('window.bridge.setSendPending(');
    final paint = after('await bridge.setMessages(');
    expect(generating, lessThan(paint));
    expect(sendPending, lessThan(paint));
    // The dispatcher level-reconciles against this field rather than
    // `isSendPending`, which it has already overwritten by then.
    expect(after('bridge.isSendPendingInPage ='), lessThan(paint));
  });
}
