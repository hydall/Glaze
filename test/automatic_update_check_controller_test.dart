import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/update_check_coordinator.dart';

void main() {
  test('deduplicates concurrent checks and respects cooldown', () async {
    var now = DateTime.utc(2026, 8, 31);
    var calls = 0;
    final pending = Completer<void>();
    final controller = AutomaticUpdateCheckController(
      interval: const Duration(hours: 1),
      now: () => now,
      check: (_) {
        calls++;
        return pending.future;
      },
    );
    addTearDown(controller.dispose);

    final first = controller.runNow(force: true);
    await controller.runNow(force: true);
    expect(calls, 1);
    pending.complete();
    await first;

    await controller.runNow();
    expect(calls, 1);
    now = now.add(const Duration(hours: 1));
    await controller.runNow();
    expect(calls, 2);
  });

  test('keeps presented update identities for the app lifetime', () async {
    Set<String>? firstSet;
    Set<String>? secondSet;
    final controller = AutomaticUpdateCheckController(
      check: (presented) async {
        if (firstSet == null) {
          firstSet = presented;
          presented.add('build-a');
        } else {
          secondSet = presented;
        }
      },
    );
    addTearDown(controller.dispose);

    await controller.runNow(force: true);
    await controller.runNow(force: true);
    expect(identical(firstSet, secondSet), isTrue);
    expect(secondSet, contains('build-a'));
  });

  test('releases the in-flight guard after an error', () async {
    var calls = 0;
    final controller = AutomaticUpdateCheckController(
      check: (_) async {
        calls++;
        if (calls == 1) throw StateError('offline');
      },
    );
    addTearDown(controller.dispose);

    await expectLater(controller.runNow(force: true), throwsStateError);
    await controller.runNow(force: true);
    expect(calls, 2);
  });
}
