import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/editing_message_provider.dart';

/// An edit session that outlives its editor blocks the whole chat.
///
/// The editor is a `<textarea>` inside the message's WebView row. Nothing on
/// the Flutter side observes whether it is still there: `editingMessageIdProvider`
/// is cleared only by the WebView's own Save/Cancel callbacks, and every send,
/// regenerate and swipe guard reads it. So when the row is rebuilt (`setMessages`
/// replaces the DOM) or the page is replaced (render process killed), the editor
/// vanishes, the provider stays set, and the composer is left read-only and
/// regenerate hidden with no way back — "tap edit, then nothing works until the
/// app is restarted".
///
/// `_resetAfterDomRework` is the one place that drops the session wherever the
/// list or the page is rebuilt. These assertions pin that wiring down.
String _extractBlockBody(String src, int fromIndex) {
  final start = src.indexOf('{', fromIndex);
  if (start == -1) return '';
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    if (src[i] == '{') {
      depth++;
    } else if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}

void main() {
  late String widgetSource;
  late String messageActionsSource;
  late String bridgeJs;

  setUpAll(() {
    widgetSource = File(
      'lib/features/chat/widgets/chat_webview_widget.dart',
    ).readAsStringSync();
    messageActionsSource = File(
      'lib/features/chat/widgets/message_actions.dart',
    ).readAsStringSync();
    bridgeJs = File(
      'assets/chat_webview/bridge/chat_bridge_controller.js',
    ).readAsStringSync();
  });

  group('the edit session is dropped whenever the DOM is rebuilt', () {
    test('_clearEditingSession nulls the provider', () {
      final idx = widgetSource.indexOf('void _clearEditingSession()');
      expect(idx, isNonNegative);
      final body = _extractBlockBody(widgetSource, idx);
      expect(body, contains('editingMessageIdProvider(charId)'));
      expect(body, contains('.state = null'));
    });

    test('_resetAfterDomRework re-arms streaming and drops the edit', () {
      final idx = widgetSource.indexOf('void _resetAfterDomRework()');
      expect(idx, isNonNegative);
      final body = _extractBlockBody(widgetSource, idx);
      expect(body, contains('_resetStreamingPresentationState()'));
      expect(body, contains('_clearEditingSession()'));
    });

    test('a page death and a failed init both clear the edit', () {
      for (final method in [
        'void _handlePageProcessGone()',
        'void _handleWebViewFailure(',
      ]) {
        final idx = widgetSource.indexOf(method);
        expect(idx, isNonNegative, reason: '$method must exist');
        // The body brace sits after the signature's closing `)`, which for
        // _handleWebViewFailure follows its named-parameter block.
        final sigEnd = widgetSource.indexOf(') {', idx);
        expect(sigEnd, isNonNegative);
        expect(
          _extractBlockBody(widgetSource, sigEnd),
          contains('_resetAfterDomRework()'),
          reason: '$method must drop the edit session',
        );
      }
    });

    test('init and a session switch clear the edit as well', () {
      for (final marker in [
        'Future<void> _initWebViewOnce()',
        'Future<void> _syncCurrentSessionToBridge()',
      ]) {
        final idx = widgetSource.indexOf(marker);
        expect(idx, isNonNegative, reason: '$marker must exist');
        expect(
          _extractBlockBody(widgetSource, idx),
          contains('_resetAfterDomRework()'),
          reason: '$marker must drop the edit session',
        );
      }
    });

    test('every full-diff reset routes through _resetAfterDomRework', () {
      expect(widgetSource, contains('onDomReset: _resetAfterDomRework'));
      expect(
        widgetSource,
        isNot(contains('onDomReset: _resetStreamingPresentationState')),
        reason: 'the DOM-reset hook must clear the edit, not just streaming',
      );
    });
  });

  group('a background update cannot destroy the open editor', () {
    test('_executeUpdateMessage skips the body rewrite while editing', () {
      final idx = bridgeJs.indexOf('_executeUpdateMessage(msg) {');
      expect(idx, isNonNegative);
      final body = _extractBlockBody(bridgeJs, idx);
      final guard = body.indexOf("if (!section.classList.contains('editing'))");
      final rewrite = body.indexOf('updateMessageContent(');
      expect(guard, isNonNegative, reason: 'the rewrite must be guarded');
      expect(rewrite, isNonNegative);
      expect(
        guard,
        lessThan(rewrite),
        reason: 'the editing guard must gate the content rewrite',
      );
    });
  });

  group('re-tapping edit reopens a lost editor', () {
    test('a same-id cycle notifies the listener (null, then the id)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final provider = editingMessageIdProvider('c1');
      final seen = <String?>[];
      container.listen<String?>(provider, (_, next) => seen.add(next));

      // First open.
      final editing = container.read(provider.notifier);
      editing.state = 'm1';
      expect(seen, ['m1']);

      // Re-tap on the same message: without the cycle a same-value write
      // notifies nobody and the WebView never sees another `startEdit`.
      if (editing.state == 'm1') editing.state = null;
      editing.state = 'm1';
      expect(seen, ['m1', null, 'm1']);
    });

    test('message_actions performs that cycle', () {
      expect(
        messageActionsSource,
        contains('if (editing.state == messageId) editing.state = null;'),
      );
      expect(messageActionsSource, contains('editing.state = messageId;'));
    });
  });
}
