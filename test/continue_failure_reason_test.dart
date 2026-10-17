import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/continue_failure_listener.dart';

void main() {
  test('a short reason is shown as it is', () {
    expect(
      continueFailureReason('Continuation produced no text'),
      'Continuation produced no text',
    );
  });

  test('provider JSON is flattened onto one line', () {
    expect(
      continueFailureReason('HTTP 400\n{\n  "error": "bad"\n}'),
      'HTTP 400 { "error": "bad" }',
    );
  });

  test('a long reason is cut short', () {
    final reason = continueFailureReason('x' * 1000);
    expect(reason.length, 301);
    expect(reason, endsWith('…'));
  });

  test('a blank reason stays blank', () {
    expect(continueFailureReason('  \n '), isEmpty);
  });
}
