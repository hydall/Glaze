import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_worker.dart';

void main() {
  const base = Duration(seconds: 60);
  const cap = Duration(seconds: 180);

  // Both reports of this are unanswerable as written: "Glaze throws a
  // TimeoutException for PromptWorker (request timed out after 60000ms) when
  // using a char imported with ST backup", and a card titled "PromptWorker
  // getting overwhelmed with too many lorebooks/regexes". Neither says how big
  // the chat was, which is the one thing that separates "an enormous import"
  // from "something is stuck" — and the message they were copied from does not
  // say either.
  group('a timeout says what timed out', () {
    test('the command and the payload size', () {
      expect(
        describeWorkerRequest('buildFromInputs', 'x' * (2 * 1024 * 1024)),
        'buildFromInputs, 2.0 MB payload',
      );
    });

    test('small payloads are reported in KB', () {
      expect(
        describeWorkerRequest('buildPrompt', 'x' * 4096),
        'buildPrompt, 4 KB payload',
      );
    });

    test('a request with no payload is named anyway', () {
      // `init` and `debugBlock` do not carry a serialized string.
      expect(describeWorkerRequest('init', null), 'init');
    });
  });

  // A flat cap is not a statement about the work; it is a statement about how
  // long Glaze will wait for an isolate it cannot interrupt. But a prompt build
  // scales with the chat it builds from, and a SillyTavern import arrives with
  // chats far larger than anything Glaze creates itself — against a fixed 60 s
  // such a character never generates at all.
  group('the budget scales with the payload', () {
    test('an ordinary chat keeps the ordinary budget', () {
      expect(timeoutForPayload(0, base: base, cap: cap), base);
      expect(
        timeoutForPayload(64 * 1024, base: base, cap: cap).inSeconds,
        60,
      );
    });

    test('a megabyte buys fifteen seconds', () {
      expect(
        timeoutForPayload(1024 * 1024, base: base, cap: cap).inSeconds,
        75,
      );
      expect(
        timeoutForPayload(4 * 1024 * 1024, base: base, cap: cap).inSeconds,
        120,
      );
    });

    test('it stops growing, so a stuck isolate is still replaced', () {
      expect(timeoutForPayload(50 * 1024 * 1024, base: base, cap: cap), cap);
    });

    test('a cap below the base is not allowed to shorten it', () {
      // Guards the test seam itself: overriding these must never produce a
      // budget smaller than the one asked for.
      expect(
        timeoutForPayload(
          8 * 1024 * 1024,
          base: base,
          cap: const Duration(seconds: 10),
        ),
        base,
      );
    });

    test('the queue tests can still shorten the deadline', () {
      // `PromptWorker.requestTimeout` is the documented override; scaling has
      // to be relative to it, not to a hard-coded minute.
      expect(
        timeoutForPayload(
          0,
          base: const Duration(milliseconds: 150),
          cap: cap,
        ),
        const Duration(milliseconds: 150),
      );
    });
  });

  test('the shipped defaults are the ones described above', () {
    expect(PromptWorker.requestTimeout, base);
    expect(PromptWorker.maxRequestTimeout, cap);
  });
}
