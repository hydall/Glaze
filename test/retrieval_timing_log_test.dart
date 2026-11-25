import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/embedding_request_gate.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/retrieval_timing.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';

void main() {
  group('RetrievalTiming', () {
    test('names every part, off parts and timeouts included', () async {
      final timing = RetrievalTiming('s1')..retrievalStarted();
      final memory = timing.part('memory', Future.value(1), active: false);
      final lorebook = timing.part('lorebook', Future.value(2), active: true);
      timing.timedOut('recall');
      final recall = timing.part('recall', Future.value(3), active: true);
      await Future.wait([memory, lorebook, recall]);

      final line = timing.describe();
      expect(line, startsWith('[retrieval] session=s1 preparingMs='));
      expect(line, contains('memory=off'));
      expect(line, matches(RegExp(r'lorebook=\d+ms ')));
      expect(line, matches(RegExp(r'recall=\d+ms\(timeout\)')));
      expect(line, contains('totalMs='));
      expect(line, isNot(contains('aborted')));
    });

    test('a part still running when the turn stops reads unfinished', () {
      final timing = RetrievalTiming('s1')..retrievalStarted();
      timing.part('recall', Completer<void>().future, active: true);

      final line = timing.describe(aborted: true);
      expect(line, contains('recall=unfinished'));
      expect(line, endsWith(' aborted'));
    });
  });

  group('embedding request log', () {
    late List<String> lines;
    late DebugPrintCallback original;

    setUp(() {
      EmbeddingRequestRateLimiter.resetForTesting();
      lines = [];
      original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
    });

    tearDown(() {
      debugPrint = original;
      EmbeddingRequestRateLimiter.resetForTesting();
    });

    // Nothing listens on port 1, so the request fails at once without
    // leaving the machine.
    const config = EmbeddingConfig(
      endpoint: 'http://127.0.0.1:1/v1',
      model: 'test-model',
      requestsPerMinute: 6000,
    );

    test(
      'a foreground request is logged with its queue and http time',
      () async {
        await expectLater(
          EmbeddingService().getEmbeddings(
            ['query'],
            config,
            foreground: true,
            captureContext: const LlmCaptureContext(stage: 'embedding.recall'),
          ),
          throwsA(anything),
        );

        final line = lines.singleWhere((l) => l.startsWith('[embedding]'));
        expect(line, contains('stage=embedding.recall foreground'));
        expect(line, matches(RegExp(r'queueMs=\d+ httpMs=\d+')));
        expect(line, contains('idleBeforeMs=-'));
        expect(line, isNot(contains('outcome=ok')));
      },
    );

    test('the second request reports how long the client sat idle', () async {
      final service = EmbeddingService();
      for (final text in ['first', 'second']) {
        await expectLater(
          service.getEmbeddings([text], config, foreground: true),
          throwsA(anything),
        );
      }

      final logged = lines.where((l) => l.startsWith('[embedding]')).toList();
      expect(logged, hasLength(2));
      expect(logged.last, matches(RegExp(r'idleBeforeMs=\d+ ')));
    });

    test('a failed background request is logged too', () async {
      await expectLater(
        EmbeddingService().getEmbeddings(['chunk'], config),
        throwsA(anything),
      );

      expect(
        lines.where((l) => l.startsWith('[embedding]')).single,
        contains(' background '),
      );
    });
  });
}
