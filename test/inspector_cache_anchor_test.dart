import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/widgets/requests/inspector_message.dart';

/// The cache anchor is the oldest message the prompt still carries. The
/// inspector marks it from the outside because neither a built prompt row nor a
/// capture knows the anchor id at construction time.
void main() {
  InspectorMessage message(
    String role, {
    bool isHistory = false,
    String content = 'text',
  }) => InspectorMessage(role: role, content: content, isHistory: isHistory);

  test('marks the first history message, not the system prefix', () {
    final marked = InspectorMessage.markCacheAnchor([
      message('system'),
      message('system', isHistory: false),
      message('user', isHistory: true),
      message('assistant', isHistory: true),
    ]);

    expect(marked[0].isCacheAnchor, isFalse);
    expect(marked[1].isCacheAnchor, isFalse);
    expect(marked[2].isCacheAnchor, isTrue);
    expect(marked[3].isCacheAnchor, isFalse);
  });

  test('a capture with no history flags falls back to the first turn', () {
    final marked = InspectorMessage.markCacheAnchor([
      message('system'),
      message('user'),
      message('assistant'),
    ]);

    expect(marked[0].isCacheAnchor, isFalse);
    expect(marked[1].isCacheAnchor, isTrue);
    expect(marked[2].isCacheAnchor, isFalse);
  });

  test('a system-only prompt has no anchor to mark', () {
    final messages = [message('system'), message('system')];
    final marked = InspectorMessage.markCacheAnchor(messages);

    expect(marked.any((m) => m.isCacheAnchor), isFalse);
  });
}
