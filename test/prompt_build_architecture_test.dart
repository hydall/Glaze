import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core prompt build files do not depend on features or own providers', () {
    final files = [
      File('lib/core/llm/prompt_inputs_collector.dart'),
      File('lib/core/llm/prompt_payload_builder.dart'),
      File('lib/core/llm/generation_context_inputs.dart'),
      File('lib/core/llm/prompt/recalled_messages_resolver.dart'),
      File('lib/core/llm/prompt/lorebook_context_resolver.dart'),
      File('lib/core/llm/prompt/memory_context_resolver.dart'),
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

  test('generation context contract excludes ordinary preset types', () {
    final source = File(
      'lib/core/llm/generation_context_inputs.dart',
    ).readAsStringSync();

    expect(source, isNot(matches(RegExp(r'\bPreset\??\s+\w+'))));
    expect(source, isNot(matches(RegExp(r'List<PresetBlock>'))));
  });

  test('shared context resolvers exclude ordinary preset types', () {
    for (final path in [
      'lib/core/llm/prompt/recalled_messages_resolver.dart',
      'lib/core/llm/prompt/lorebook_context_resolver.dart',
      'lib/core/llm/prompt/memory_context_resolver.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains("models/preset.dart")));
      expect(
        source,
        isNot(matches(RegExp(r'\bPreset(?:Block|Regex)?\??\s+\w+'))),
      );
    }
  });
}
