import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Memory drafting must not talk to a transport on its own.
///
/// It used to: the generator built a `ChatTransportRequest` and awaited
/// `transport.stream` directly, which meant no retry policy. Every other
/// auxiliary call in the app goes through `AuxLlmClient`, which retries 5xx
/// and timeouts three times with backoff — so a provider gateway answering one
/// request with 504 was invisible everywhere except here, where it failed the
/// draft outright and left the reader to press the button again.
void main() {
  final source = File(
    'lib/features/chat/memory_draft_generator.dart',
  ).readAsStringSync();

  test('memory drafting goes through the shared auxiliary client', () {
    expect(source, contains('AuxLlmClient'));
    expect(source, contains('_llm.callOnce('));
  });

  test('memory drafting does not drive a transport itself', () {
    expect(
      source,
      isNot(contains('transport.stream(')),
      reason: 'a direct transport call bypasses the retry policy',
    );
    expect(source, isNot(contains('pickChatTransport(')));
  });

  test('the summary is on the same client, for the same reason', () {
    final summary = File(
      'lib/core/llm/summary_service.dart',
    ).readAsStringSync();
    expect(summary, contains('_llm.callOnce('));
    expect(summary, isNot(contains('transport.stream(')));
  });
}
