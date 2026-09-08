import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';

void main() {
  group('ChatMessageMapper agentSwipeFinalCount', () {
    final ctx = const ChatMessageMapperContext(isGenerating: false);

    ChatMessage makeMsg(List<AgentSwipe> agentSwipes, {int agentSwipeId = 0}) {
      return ChatMessage(
        id: 'm1',
        role: 'assistant',
        content: agentSwipes.isNotEmpty
            ? agentSwipes[agentSwipeId.clamp(0, agentSwipes.length - 1)].content
            : '',
        agentSwipes: agentSwipes,
        agentSwipeId: agentSwipeId,
      );
    }

    test(
      'single final + single cleaned → agentSwipeFinalCount=2 (show switcher)',
      () {
        final msg = makeMsg([
          const AgentSwipe(content: 'orig', kind: 'final'),
          const AgentSwipe(
            content: 'cleaned',
            kind: 'cleaned',
            parentSwipeId: 0,
          ),
        ]);
        final map = ChatMessageMapper.toMap(msg, ctx, isLast: true);
        expect(
          map['agentSwipeFinalCount'],
          2,
          reason:
              '2 agent swipes → blue switcher shown so user can diff cleaner',
        );
      },
    );

    test('two finals + one cleaned → agentSwipeFinalCount=3', () {
      final msg = makeMsg([
        const AgentSwipe(content: 'orig', kind: 'final'),
        const AgentSwipe(content: 'regen', kind: 'final'),
        const AgentSwipe(content: 'cleaned', kind: 'cleaned', parentSwipeId: 1),
      ], agentSwipeId: 2);
      final map = ChatMessageMapper.toMap(msg, ctx, isLast: true);
      expect(
        map['agentSwipeFinalCount'],
        3,
        reason: '3 agent swipes → blue switcher shown',
      );
    });

    test('empty agentSwipes → no agentSwipeFinalCount', () {
      final msg = makeMsg(const []);
      final map = ChatMessageMapper.toMap(msg, ctx, isLast: true);
      expect(map.containsKey('agentSwipeFinalCount'), isFalse);
    });

    test('single final only → no agentSwipeFinalCount', () {
      final msg = makeMsg([const AgentSwipe(content: 'only', kind: 'final')]);
      final map = ChatMessageMapper.toMap(msg, ctx, isLast: true);
      expect(
        map.containsKey('agentSwipeFinalCount'),
        isFalse,
        reason: 'Only 1 agent swipe → no switcher',
      );
    });

    test('three finals → agentSwipeFinalCount=3', () {
      final msg = makeMsg([
        const AgentSwipe(content: 'f1', kind: 'final'),
        const AgentSwipe(content: 'f2', kind: 'final'),
        const AgentSwipe(content: 'f3', kind: 'final'),
      ], agentSwipeId: 2);
      final map = ChatMessageMapper.toMap(msg, ctx, isLast: true);
      expect(map['agentSwipeFinalCount'], 3);
    });
  });
}
