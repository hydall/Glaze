import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/converters/structured_response.dart';

void main() {
  test('unwrapStructuredResponse joins prefix and content', () {
    expect(
      unwrapStructuredResponse('{"prefix":"<thinking>","content":"hello there"}'),
      '<thinking>hello there',
    );
  });

  test('unwrapStructuredResponse returns raw text when JSON is malformed', () {
    expect(unwrapStructuredResponse('not json at all'), 'not json at all');
  });

  test('unwrapStructuredResponse returns raw text for an empty string', () {
    expect(unwrapStructuredResponse(''), '');
  });

  test('unwrapStructuredResponse trims surrounding whitespace', () {
    expect(
      unwrapStructuredResponse('  {"prefix":"<thinking>","content":"x"}  '),
      '<thinking>x',
    );
  });
}
