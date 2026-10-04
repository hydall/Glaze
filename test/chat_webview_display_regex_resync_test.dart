import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_webview_build_listeners.dart';

/// The display-regex list is a first-paint input: the initializer awaits the
/// provider before it maps the opening batch. The post-init check must only
/// re-render when the list moved *after* that paint. The regression it guards
/// is the list's own first load being mistaken for a change, which forced a
/// duplicate full render of every first open — a large chat shows that as the
/// chat reloading a moment after it opens.
void main() {
  PresetRegex regex(String id, {bool disabled = false}) => PresetRegex(
    id: id,
    name: id,
    regex: 'x',
    disabled: disabled,
  );

  group('displayRegexResyncNeeded', () {
    test('the list\'s first load is not a stale render', () {
      final loaded = [regex('a'), regex('b')];
      expect(
        displayRegexResyncNeeded(loaded, [regex('a'), regex('b')]),
        isFalse,
      );
    });

    test('a list that changes after the paint is a stale render', () {
      expect(
        displayRegexResyncNeeded([regex('a')], [regex('a'), regex('b')]),
        isTrue,
      );
      expect(displayRegexResyncNeeded([regex('a')], [regex('b')]), isTrue);
      expect(
        displayRegexResyncNeeded(
          [regex('a', disabled: false)],
          [regex('a', disabled: true)],
        ),
        isTrue,
      );
    });

    test('an init that never painted has nothing to correct', () {
      expect(displayRegexResyncNeeded(null, [regex('a')]), isFalse);
    });
  });

  group('wiring', () {
    test('the initializer records the painted list before it paints', () {
      final source = File(
        'lib/features/chat/widgets/chat_webview_initializer.dart',
      ).readAsStringSync();
      final capture = source.indexOf(
        'paintedDisplayRegexes = bridge.displayRegexes;',
      );
      final paint = source.indexOf('await bridge.setMessages(');
      expect(capture, isNonNegative);
      expect(paint, isNonNegative);
      expect(capture, lessThan(paint));
    });

    test('the widget compares the painted list instead of a stale boolean', () {
      final source = File(
        'lib/features/chat/widgets/chat_webview_widget.dart',
      ).readAsStringSync();
      // The initializer's paint list reaches the state the check reads.
      expect(
        source,
        contains(
          '_syncState.paintedDisplayRegexes = initializer.paintedDisplayRegexes;',
        ),
      );
      expect(source, contains('displayRegexResyncNeeded('));
      // The old flag fired on the first load as well; it must be gone.
      expect(source, isNot(contains('_syncState.regexContextStale')));
    });
  });
}
