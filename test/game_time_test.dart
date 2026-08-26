import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/models/tracker.dart';

Tracker tracker(String name, String value) =>
    Tracker(sessionId: 'session', name: name, value: value, scope: 'ledger');

void main() {
  group('GameTimeState.fromTrackers', () {
    test('parses and normalizes clock trackers', () {
      final state = GameTimeState.fromTrackers([
        tracker(GameTimeState.timeKey, '9:5'),
        tracker(GameTimeState.dateKey, '03.04.2027'),
        tracker(GameTimeState.dayKey, '2'),
      ]);

      expect(state.time, '09:05');
      expect(state.date, '03.04.2027');
      expect(state.day, 2);
      expect(state.format(), '03.04.2027 · RP_Day 2 · 09:05');
    });

    test('rejects out-of-range values and ignores empty rows', () {
      final state = GameTimeState.fromTrackers([
        tracker(GameTimeState.timeKey, '25:99'),
        tracker(GameTimeState.dateKey, ''),
        tracker(GameTimeState.dayKey, 'not-a-number'),
      ]);

      expect(state.time, isNull);
      expect(state.date, isNull);
      expect(state.day, isNull);
      expect(state.format(), isNull);
    });

    test('requires a complete date, RP day, and time for a stamp', () {
      expect(GameTimeState(time: '12:30').format(), isNull);
      expect(GameTimeState(time: '12:30', day: 0).format(), isNull);
      expect(
        const GameTimeState(
          time: '12:30',
          date: '03.04.2027',
          day: 0,
        ).formatEnglish(),
        '03.04.2027 · RP_Day 0 · 12:30',
      );
    });

    test('normalizes dashed ledger dates to the display contract', () {
      final state = GameTimeState.fromTrackers([
        tracker(GameTimeState.timeKey, '14:15'),
        tracker(GameTimeState.dateKey, '26-08-2026'),
        tracker(GameTimeState.dayKey, '7'),
      ]);

      expect(state.format(), '26.08.2026 · RP_Day 7 · 14:15');
    });

    test('rejects impossible dates and negative RP days', () {
      final impossibleDate = GameTimeState.fromTrackers([
        tracker(GameTimeState.timeKey, '12:00'),
        tracker(GameTimeState.dateKey, '31.02.2026'),
        tracker(GameTimeState.dayKey, '0'),
      ]);
      final negativeDay = GameTimeState.fromTrackers([
        tracker(GameTimeState.timeKey, '12:00'),
        tracker(GameTimeState.dateKey, '01.02.2026'),
        tracker(GameTimeState.dayKey, '-1'),
      ]);

      expect(impossibleDate.format(), isNull);
      expect(negativeDay.format(), isNull);
    });
  });

  group('GameTimeState.expandMacros', () {
    test('expands game-clock macros only', () {
      const state = GameTimeState(time: '18:40', date: '12.05.2027', day: 3);

      expect(
        state.expandMacros(
          'Time {{gametime}}, date {{gamedate}}, day {{gameday}}.',
        ),
        'Time 18:40, date 12.05.2027, day 3.',
      );
    });

    test('missing clock parts expand to an empty string', () {
      const state = GameTimeState(time: '08:00');

      expect(state.expandMacros('{{gamedate}}|{{gameday}}'), '|');
    });

    test('leaves unrelated macros untouched', () {
      const state = GameTimeState(time: '08:00');

      expect(
        state.expandMacros('{{char}} {{roll::1d6}}'),
        '{{char}} {{roll::1d6}}',
      );
    });
  });

  group('replaceMacros game-clock macros', () {
    const ctx = MacroContext(
      charName: 'Alison',
      charId: 'character',
      sessionId: 'session',
      gameTime: '21:15',
      gameDate: '04.06.2027',
      gameDay: '5',
    );

    test('expands {{gametime}} / {{gamedate}} / {{gameday}}', () {
      final result = replaceMacros(
        'At {{gametime}} on {{gamedate}} (day {{gameday}}).',
        ctx,
      );

      expect(result.text, 'At 21:15 on 04.06.2027 (day 5).');
    });

    test('real-time macros are unaffected by the game clock', () {
      final result = replaceMacros('{{gametime}}', ctx);

      expect(result.text, '21:15');
    });

    test('missing game clock expands to an empty string', () {
      const emptyCtx = MacroContext(
        charName: 'Alison',
        charId: 'character',
        sessionId: 'session',
      );

      expect(replaceMacros('<{{gametime}}>', emptyCtx).text, '<>');
    });

    test('MacroContext json round-trip preserves the game clock', () {
      final restored = MacroContext.fromJson(ctx.toJson());

      expect(restored.gameTime, '21:15');
      expect(restored.gameDate, '04.06.2027');
      expect(restored.gameDay, '5');
    });
  });
}
