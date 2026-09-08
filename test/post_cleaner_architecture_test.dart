import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PostCleanerService does not import feature code', () {
    final file = File('lib/core/llm/post_cleaner_service.dart');
    final featureImport = RegExp(r'''import\s+['"][^'"]*features/''');

    expect(
      file.readAsStringSync(),
      isNot(matches(featureImport)),
      reason: '${file.path} must receive feature-layer effects by constructor',
    );
  });
}
