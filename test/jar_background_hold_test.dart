import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/generation_notification_service.dart';

/// The brace group in [source] starting at or after [from].
({String text, int end}) _braceGroup(String source, int from) {
  final open = source.indexOf('{', from);
  expect(open, greaterThan(-1), reason: 'no brace after offset $from');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return (text: source.substring(open, i + 1), end: i + 1);
    }
  }
  fail('unbalanced braces after offset $from');
}

/// The body of the method named [signature] in [source]. A named-parameter
/// list is a brace group of its own, so it is skipped when the body follows.
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThan(-1), reason: 'missing $signature');
  final first = _braceGroup(source, start);
  final between = source.substring(
    first.end,
    source.indexOf('{', first.end),
  );
  return between.contains(')')
      ? _braceGroup(source, first.end).text
      : first.text;
}

void main() {
  final extractor = File(
    'lib/features/catalog/services/janitor_extractor.dart',
  ).readAsStringSync();

  // Generation survives being backgrounded because it holds a dataSync
  // foreground service for its duration. A JAR extraction is minutes of
  // network round trips plus an LLM call and held nothing, so Android was free
  // to freeze or kill the process and the work was simply lost.
  group('both extraction phases hold the foreground', () {
    test('the capture phase acquires and always releases', () {
      final body = _bodyOf(extractor, 'Future<ExtractionResult> extract(');

      expect(body, contains('acquireWorkHold('));
      expect(body, contains("'notification_extracting'.tr()"));
      // In the `finally` beside `setActive(false)`, so an extraction that
      // throws does not leave a foreground service running for the rest of
      // the session.
      expect(
        body,
        contains(RegExp(r'finally \{[^}]*hold\.release\(\)', dotAll: true)),
      );
    });

    test('the commit phase does too, since the rebuild is an LLM call', () {
      // Losing it after the capture already succeeded is the worst moment to
      // be killed.
      final body = _bodyOf(extractor, 'Future<CommitResult> commit(');

      expect(body, contains('acquireWorkHold('));
      expect(body, contains("'notification_importing'.tr()"));
      expect(
        body,
        contains(RegExp(r'finally \{[^}]*hold\.release\(\)', dotAll: true)),
      );
    });

    test('the inner commit is the one with the four return paths', () {
      // The hold is a thin wrapper rather than a try/finally around a body
      // that returns from four places; this is what keeps them separate.
      expect(extractor, contains('Future<CommitResult> _commit('));
      expect(_bodyOf(extractor, 'Future<CommitResult> _commit('),
          isNot(contains('acquireWorkHold(')));
    });
  });

  group('the hold itself', () {
    test('is handed out on every platform, so callers need no branch', () async {
      final hold = await GenerationNotificationService.instance.acquireWorkHold(
        title: 'Glaze',
        text: 'test',
      );
      expect(hold, isA<ForegroundWorkHold>());
      await hold.release();
    });

    test('releasing twice is safe', () async {
      // Both phases release from a `finally`, and a caller that also releases
      // early must not drive the service's hold count negative.
      final hold = await GenerationNotificationService.instance.acquireWorkHold(
        title: 'Glaze',
        text: 'test',
      );
      await hold.release();
      await hold.release();
    });

    test('does not claim the app is generating', () {
      // `isGenerating` gates other behaviour; an extraction needs the process
      // kept alive, not to be mistaken for a chat reply in flight.
      final service = File(
        'lib/core/services/generation_notification_service.dart',
      ).readAsStringSync();
      final body = _bodyOf(service, 'Future<ForegroundWorkHold> acquireWorkHold(');

      expect(body, isNot(contains('_generationLeaseCount')));
    });
  });

  test('the notification text exists in both languages', () {
    for (final path in [
      'assets/translations/en.json',
      'assets/translations/ru.json',
    ]) {
      final json = File(path).readAsStringSync();
      expect(json, contains('"notification_extracting"'), reason: path);
      expect(json, contains('"notification_importing"'), reason: path);
    }
  });
}
