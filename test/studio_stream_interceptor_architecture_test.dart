import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('StudioStreamInterceptor does not depend on feature state', () {
    final file = File('lib/core/llm/studio/studio_stream_interceptor.dart');
    final forbiddenImport = RegExp(
      r'''import\s+['"][^'"]*(?:features/|flutter_riverpod)[^'"]*['"]''',
    );

    expect(
      file.readAsStringSync(),
      isNot(matches(forbiddenImport)),
      reason: '${file.path} must remain below the feature state layer',
    );
  });
}
