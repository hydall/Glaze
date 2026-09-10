import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_canon_authority.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';

void main() {
  TrackerSnapshot snapshot(int minute, {bool committed = true}) {
    return TrackerSnapshot(
      sessionId: 'session',
      messageId: 'message-$minute',
      committed: committed,
      trackers: [
        Tracker(sessionId: 'session', name: 'world:date', value: '08.09.0755'),
        const Tracker(sessionId: 'session', name: 'world:day', value: '0'),
        Tracker(
          sessionId: 'session',
          name: 'world:time',
          value: '09:${minute.toString().padLeft(2, '0')}',
        ),
      ],
    );
  }

  test('selects the newest valid window and presents it oldest first', () {
    final newestFirst = [
      for (var minute = 10; minute >= 1; minute--) snapshot(minute),
    ];

    final clocks = LedgerCanonAuthority.recentGameClockFromSnapshots(
      newestFirst,
      limit: 5,
    );

    expect(clocks, [
      '08.09.0755 · day 0 · 09:06',
      '08.09.0755 · day 0 · 09:07',
      '08.09.0755 · day 0 · 09:08',
      '08.09.0755 · day 0 · 09:09',
      '08.09.0755 · day 0 · 09:10',
    ]);
  });

  test('incomplete and tentative snapshots do not consume the limit', () {
    final incomplete = snapshot(10).copyWith(
      trackers: snapshot(
        10,
      ).trackers.where((item) => item.name != 'world:day').toList(),
    );
    final clocks = LedgerCanonAuthority.recentGameClockFromSnapshots([
      incomplete,
      snapshot(9, committed: false),
      snapshot(8),
      snapshot(7),
    ], limit: 2);

    expect(clocks, [
      '08.09.0755 · day 0 · 09:07',
      '08.09.0755 · day 0 · 09:08',
    ]);
  });

  test('uses transcript order and excludes inactive committed variations', () {
    final inactive = snapshot(
      59,
    ).copyWith(messageId: 'second', swipeId: 0, agentSwipeId: 0);
    final active = snapshot(
      2,
    ).copyWith(messageId: 'second', swipeId: 1, agentSwipeId: 1);
    final first = snapshot(1).copyWith(messageId: 'first');

    final clocks = LedgerCanonAuthority.recentActiveGameClock(
      const [
        ChatMessage(id: 'first', role: 'assistant', content: 'First'),
        ChatMessage(id: 'user', role: 'user', content: 'User'),
        ChatMessage(
          id: 'second',
          role: 'assistant',
          content: 'Active',
          swipeId: 1,
          agentSwipeId: 1,
        ),
      ],
      [inactive, first, active],
      limit: 5,
    );

    expect(clocks, [
      '08.09.0755 · day 0 · 09:01',
      '08.09.0755 · day 0 · 09:02',
    ]);
  });
}
