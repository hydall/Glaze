import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/extensions/services/block_context_builder.dart';

ChatMessage _msg(String id, String role, String content) => ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: 0,
    );

void main() {
  final history = [
    _msg('u1', 'user', 'hi'),
    _msg('a1', 'assistant', 'hello'),
    _msg('u2', 'user', 'more'),
    _msg('a2', 'assistant', 'reply two'),
    _msg('u3', 'user', 'latest user'),
    _msg('a3', 'assistant', 'latest assistant'),
  ];

  test('count 1 on old anchor returns that message, not chat tail', () {
    final ctx = buildContextMessages(
      messages: history,
      anchorMessageId: 'a2',
      count: 1,
    );
    expect(ctx.map((m) => m.id).toList(), ['a2']);
  });

  test('count 2 on old anchor returns U+A pair ending at anchor', () {
    final ctx = buildContextMessages(
      messages: history,
      anchorMessageId: 'a2',
      count: 2,
    );
    expect(ctx.map((m) => m.id).toList(), ['u2', 'a2']);
  });

  test('count -1 on anchor returns full history up to anchor', () {
    final ctx = buildContextMessages(
      messages: history,
      anchorMessageId: 'a2',
      count: -1,
    );
    expect(ctx.map((m) => m.id).toList(), ['u1', 'a1', 'u2', 'a2']);
  });

  test('latest anchor matches tail behavior for count 1', () {
    final ctx = buildContextMessages(
      messages: history,
      anchorMessageId: 'a3',
      count: 1,
    );
    expect(ctx.map((m) => m.id).toList(), ['a3']);
  });

  test('messagesBeforeAnchor excludes anchor and later messages', () {
    final before = messagesBeforeAnchor(history, 'a2');
    expect(before.map((m) => m.id).toList(), ['u1', 'a1', 'u2']);
  });
}
