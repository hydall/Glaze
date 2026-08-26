import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/game_time_message_stamp.dart';

void main() {
  test('stamps only the addressed nested variation', () {
    const message = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'second',
      swipes: ['green'],
      agentSwipes: [
        AgentSwipe(content: 'first'),
        AgentSwipe(content: 'second', kind: 'cleaned'),
      ],
      agentSwipeId: 1,
    );

    final stamped = stampGameTimeForVariation(
      message,
      swipeId: 0,
      agentSwipeId: 1,
      time: '12.05.2027 · RP_Day 2 · 14:15',
    );

    expect(stamped.time, '12.05.2027 · RP_Day 2 · 14:15');
    expect(stamped.agentSwipes[0].time, isNull);
    expect(stamped.agentSwipes[1].time, stamped.time);
    final stored = stamped.swipesMeta.single['agentSwipes'] as List<dynamic>;
    expect((stored[0] as Map<String, dynamic>)['time'], isNull);
    expect((stored[1] as Map<String, dynamic>)['time'], stamped.time);
  });

  test('does not project a non-active variation clock onto the message', () {
    const message = ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'first',
      time: '12.05.2027 · RP_Day 2 · 14:12',
      swipes: ['first', 'second'],
      swipeId: 0,
      agentSwipes: [
        AgentSwipe(content: 'first', time: '12.05.2027 · RP_Day 2 · 14:12'),
      ],
    );

    final stamped = stampGameTimeForVariation(
      message,
      swipeId: 1,
      agentSwipeId: 0,
      time: '12.05.2027 · RP_Day 2 · 14:15',
    );

    expect(stamped.time, message.time);
    final nested = stamped.swipesMeta[1]['agentSwipes'] as List<dynamic>;
    expect((nested.single as Map<String, dynamic>)['time'], contains('14:15'));
  });
}
