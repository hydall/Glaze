import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_worker.dart';

void main() {
  late PromptWorker worker;

  setUp(() async {
    worker = await PromptWorker.ensureInitialized();
    PromptWorker.requestTimeout = const Duration(milliseconds: 150);
  });

  tearDown(() {
    worker.dispose();
    PromptWorker.requestTimeout = const Duration(seconds: 60);
  });

  test(
    'queued request survives active request timeout and worker restart',
    () async {
      final timedOut = worker.debugBlock(
        const Duration(milliseconds: 500),
        'slow',
      );
      final retained = worker.debugBlock(Duration.zero, 'retained');

      await expectLater(timedOut, throwsA(isA<TimeoutException>()));
      await expectLater(retained, completion('retained'));
    },
  );

  test(
    'foreground requests are dispatched before queued diagnostics',
    () async {
      PromptWorker.requestTimeout = const Duration(seconds: 2);
      final active = worker.debugBlock(
        const Duration(milliseconds: 100),
        'active',
      );
      final order = <String>[];
      final background = worker
          .debugBlock(Duration.zero, 'background')
          .then(order.add);
      final foreground = worker
          .debugBlock(
            Duration.zero,
            'foreground',
            priority: PromptWorkerPriority.foreground,
          )
          .then(order.add);

      await active;
      await Future.wait([background, foreground]);

      expect(order, ['foreground', 'background']);
    },
  );
}
