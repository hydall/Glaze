import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core prompt build files do not depend on features or own providers', () {
    final files = [
      File('lib/core/llm/prompt_inputs_collector.dart'),
      File('lib/core/llm/prompt_payload_builder.dart'),
    ];
    final featureImport = RegExp(r'''import\s+['"][^'"]*features/[^'"]*['"]''');
    final providerDeclaration = RegExp(
      r'''\b(?:Provider|StateProvider|FutureProvider)<[^;=]+\s+\w+Provider\s*=''',
    );

    for (final file in files) {
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(matches(featureImport)),
        reason: '${file.path} must receive feature dependencies by callback',
      );
      expect(
        source,
        isNot(matches(providerDeclaration)),
        reason: '${file.path} must not own Riverpod provider composition',
      );
    }
  });
}
