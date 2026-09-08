import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SummaryService remains provider-free and below features', () {
    final file = File('lib/core/llm/summary_service.dart');
    final forbiddenImport = RegExp(
      r'''import\s+['"][^'"]*(?:features/|flutter_riverpod|/state/|\.\./state/)[^'"]*['"]''',
    );
    final providerDefinition = RegExp(
      r'''\b(?:Provider|FutureProvider|StateProvider|WidgetRef)\b''',
    );
    final source = file.readAsStringSync();

    expect(
      source,
      isNot(matches(forbiddenImport)),
      reason: '${file.path} must receive dependencies by constructor',
    );
    expect(
      source,
      isNot(matches(providerDefinition)),
      reason: '${file.path} must not contain provider composition',
    );
  });
}
