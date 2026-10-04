import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The preloader runs against a live WebView, so the death wiring is pinned on
/// the source — the same approach the other WebView lifecycle tests use. What
/// matters is that a render-process death during preload drops the shared
/// keep-alive instead of leaving a corpse for the first chat to re-attach.
void main() {
  late final String source = File(
    'lib/features/chat/widgets/chat_webview_preload.dart',
  ).readAsStringSync();

  test('a preload process death disposes the shared keep-alive', () {
    expect(source, contains('onRenderProcessGone:'));
    expect(source, contains('onWebContentProcessDidTerminate:'));
    expect(
      source,
      contains('InAppWebViewController.disposeKeepAlive(chatWebViewKeepAlive)'),
    );
  });

  test('the dead preload is retired, not remounted into a chat attach', () {
    // Setting `_preloaded` removes the preloader's WebView and stops it from
    // building a replacement; remounting would race a chat that is already
    // attaching to the same keep-alive.
    final handler = source.indexOf('_handlePreloadProcessGone');
    final dispose = source.indexOf('disposeKeepAlive', handler);
    expect(handler, isNonNegative);
    expect(dispose, greaterThan(handler));
    expect(source, contains('if (!mounted || _preloaded) return;'));
  });
}
