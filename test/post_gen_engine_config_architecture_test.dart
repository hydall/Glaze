import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PostGenEngineConfig is independent of providers and features', () {
    final file = File('lib/core/llm/post_gen_engine_config.dart');
    final forbiddenImport = RegExp(
      r'''import\s+['"][^'"]*(?:features/|flutter_riverpod|/state/|\.\./state/|_providers?\.dart)[^'"]*['"]''',
    );

    expect(
      file.readAsStringSync(),
      isNot(matches(forbiddenImport)),
      reason: '${file.path} must remain an immutable provider-free DTO',
    );
  });
}
