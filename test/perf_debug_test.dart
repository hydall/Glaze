import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/debug/perf_debug.dart';

void main() {
  test('Chat WebView profiling is inert without its compile-time define', () {
    PerfDebug.resetChatWebViewSnapshot();
    PerfDebug.chatScreenBuilt();
    PerfDebug.chatWebViewWidgetInitialized();
    PerfDebug.chatWebViewInitAttempted();
    PerfDebug.chatWebViewSyncResult(
      runMessageSync: true,
      sessionSwitched: true,
    );

    final snapshot = PerfDebug.chatWebViewSnapshot();
    if (!PerfDebug.logChatWebView) {
      expect(snapshot.chatScreenBuilds, 0);
      expect(snapshot.widgetInits, 0);
      expect(snapshot.initAttempts, 0);
      expect(snapshot.syncUpdates, 0);
    }
  });
}
