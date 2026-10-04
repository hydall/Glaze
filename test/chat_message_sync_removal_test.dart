import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_bridge_controller.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_message_sync.dart';

void main() {
  group('ChatMessageSync removals', () {
    test('mid-chat delete removes only the deleted id', () async {
      final bridge = _RecordingBridge();
      final a = _msg('a1', 'assistant');
      final u = _msg('u1', 'user');
      final b = _msg('a2', 'assistant');

      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: [a, u, b],
        newMsgs: [a, b],
        visibleStartIndex: 0,
        busy: false,
        sessionSwitching: false,
      );

      expect(bridge.removedIds, ['u1']);
      expect(bridge.clearAllCalls, 0);
      expect(bridge.setMessagesCalls, isEmpty);
    });

    test('bulk delete of non-adjacent messages removes each id', () async {
      final bridge = _RecordingBridge();
      final msgs = [
        for (var i = 0; i < 6; i++)
          _msg('m$i', i.isEven ? 'user' : 'assistant'),
      ];

      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: msgs,
        newMsgs: [msgs[0], msgs[3], msgs[5]],
        visibleStartIndex: 0,
        busy: false,
        sessionSwitching: false,
      );

      expect(bridge.removedIds, ['m1', 'm2', 'm4']);
      expect(bridge.clearAllCalls, 0);
    });

    test('head truncation still removes the dropped prefix', () async {
      final bridge = _RecordingBridge();
      final msgs = [for (var i = 0; i < 4; i++) _msg('m$i', 'user')];

      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: msgs,
        newMsgs: msgs.sublist(2),
        visibleStartIndex: 2,
        busy: false,
        sessionSwitching: false,
      );

      expect(bridge.removedIds, ['m0', 'm1']);
      expect(bridge.clearAllCalls, 0);
    });

    test('head trim and a mid-chat delete in one diff remove both', () async {
      final bridge = _RecordingBridge();
      final msgs = [for (var i = 0; i < 6; i++) _msg('m$i', 'user')];

      // The scrollback window moved forward (m0 left the window) while m3 was
      // deleted. Handling only the prefix would leave m3 stuck in the DOM.
      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: msgs,
        newMsgs: [msgs[1], msgs[2], msgs[4], msgs[5]],
        visibleStartIndex: 1,
        busy: false,
        sessionSwitching: false,
      );

      expect(bridge.removedIds, ['m0', 'm3']);
      expect(bridge.clearAllCalls, 0);
    });

    test('a reorder still falls back to a full re-render', () async {
      final bridge = _RecordingBridge();
      final a1 = _msg('a1', 'assistant');
      final u1 = _msg('u1', 'user');
      final a2 = _msg('a2', 'assistant');
      final u2 = _msg('u2', 'user');

      // Shorter *and* reordered: not a pure removal, so the ids the WebView
      // holds cannot be reconciled one by one.
      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: [a1, u1, a2, u2],
        newMsgs: [a1, a2, u1],
        visibleStartIndex: 0,
        busy: false,
        sessionSwitching: false,
      );

      expect(bridge.removedIds, isEmpty);
      expect(bridge.clearAllCalls, 1);
      expect(bridge.setMessagesCalls, [
        ['a1', 'a2', 'u1'],
      ]);
    });

    test('emptying the chat re-renders instead of only clearing', () async {
      final bridge = _RecordingBridge();

      // `clearAll` raises the page's loading screen for the `setMessages` that
      // follows it everywhere else. Without one here the spinner stayed up over
      // the emptied chat and nothing rendered until the session was re-entered.
      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: [_msg('a1', 'assistant')],
        newMsgs: const [],
        visibleStartIndex: 0,
        busy: false,
        sessionSwitching: false,
      );

      expect(bridge.clearAllCalls, 1);
      expect(bridge.setMessagesCalls, [<String>[]]);
      expect(bridge.removedIds, isEmpty);
    });

    test('an unrelated shorter list falls back to a full re-render', () async {
      final bridge = _RecordingBridge();

      await const ChatMessageSync().sync(
        bridge: bridge,
        oldMsgs: [_msg('a1', 'assistant'), _msg('u1', 'user')],
        newMsgs: [_msg('x9', 'assistant')],
        visibleStartIndex: 0,
        busy: false,
        sessionSwitching: false,
      );

      expect(bridge.removedIds, isEmpty);
      expect(bridge.clearAllCalls, 1);
    });
  });
}

ChatMessage _msg(String id, String role) =>
    ChatMessage(id: id, role: role, content: role, timestamp: 1);

class _RecordingBridge implements ChatBridgeController {
  final List<String> removedIds = [];
  final List<List<String>> setMessagesCalls = [];
  final List<String?> lastMessageIds = [];
  int clearAllCalls = 0;

  @override
  Future<void> removeMessage(String messageId) async {
    removedIds.add(messageId);
  }

  @override
  Future<void> clearAll({bool keepPlaceholder = true}) async {
    clearAllCalls++;
  }

  @override
  Future<void> setMessages(
    List<ChatMessage> messages, {
    int visibleStartIndex = 0,
    bool preserveScroll = false,
  }) async {
    setMessagesCalls.add(messages.map((m) => m.id).toList());
  }

  @override
  Future<void> setLastMessage(String? messageId) async {
    lastMessageIds.add(messageId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
