import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initial memory membership is seeded before messages are mapped', () {
    final source = File(
      'lib/features/chat/widgets/chat_webview_initializer.dart',
    ).readAsStringSync();
    final runStart = source.indexOf('Future<void> run() async');
    final memorySeed = source.indexOf(
      'await bridge.updateMemoryBookData(',
      runStart,
    );
    final messageSet = source.indexOf('await bridge.setMessages(', runStart);

    expect(runStart, isNonNegative);
    expect(memorySeed, isNonNegative);
    expect(messageSet, isNonNegative);
    expect(memorySeed, lessThan(messageSet));
    expect(
      source.substring(memorySeed, messageSet),
      contains('patchMessages: false'),
    );
  });
}
