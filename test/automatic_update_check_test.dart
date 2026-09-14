import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/update_check_coordinator.dart';

/// #137 reports that the update popup only appears at launch and nothing
/// re-checks afterwards. That was fixed by PR #350, which added this
/// controller — these hold the behaviour the card asked for in place, since
/// nothing was covering it.
void main() {
  late List<Set<String>> calls;
  late DateTime clock;

  AutomaticUpdateCheckController build({
    Duration interval = const Duration(hours: 1),
  }) => AutomaticUpdateCheckController(
    check: (ids) async => calls.add(ids),
    interval: interval,
    now: () => clock,
  );

  setUp(() {
    calls = [];
    clock = DateTime.utc(2026, 9, 14, 12);
  });

  test('starting checks immediately rather than waiting out the interval', () async {
    final controller = build()..start();
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1));
    controller.dispose();
  });

  test('#137 — coming back to the foreground re-checks', () async {
    final controller = build()..start();
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1));

    controller.pause();
    // Away for longer than the interval: the reader has been elsewhere, and a
    // build may well have landed in the meantime.
    clock = clock.add(const Duration(hours: 2));
    controller.resume();
    await Future<void>.delayed(Duration.zero);

    expect(calls, hasLength(2));
    controller.dispose();
  });

  test('a quick trip away does not re-check on every resume', () async {
    final controller = build()..start();
    await Future<void>.delayed(Duration.zero);

    controller.pause();
    clock = clock.add(const Duration(minutes: 5));
    controller.resume();
    await Future<void>.delayed(Duration.zero);

    expect(calls, hasLength(1), reason: 'still inside the interval');
    controller.dispose();
  });

  test('the same set of presented ids is carried across checks', () async {
    final controller = build()..start();
    await Future<void>.delayed(Duration.zero);
    calls.first.add('some-sha');

    clock = clock.add(const Duration(hours: 2));
    await controller.runNow();
    expect(calls, hasLength(2));
    expect(
      calls.last,
      contains('some-sha'),
      reason: 'a build already presented must not be presented again',
    );
    controller.dispose();
  });

  test('runNow(force: true) ignores the interval', () async {
    final controller = build()..start();
    await Future<void>.delayed(Duration.zero);

    await controller.runNow();
    expect(calls, hasLength(1), reason: 'throttled');

    await controller.runNow(force: true);
    expect(calls, hasLength(2));
    controller.dispose();
  });

  test('a check still running is never started a second time', () async {
    var running = 0;
    var peak = 0;
    final gate = Completer<void>();
    final controller = AutomaticUpdateCheckController(
      check: (_) async {
        running++;
        peak = peak > running ? peak : running;
        await gate.future;
        running--;
      },
      now: () => clock,
    )..start();

    await Future<void>.delayed(Duration.zero);
    await controller.runNow(force: true);
    gate.complete();
    await Future<void>.delayed(Duration.zero);

    expect(peak, 1);
    controller.dispose();
  });
}
