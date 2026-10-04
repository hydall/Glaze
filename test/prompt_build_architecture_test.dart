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
      File('lib/core/llm/studio/studio_context.dart'),
      File('lib/core/llm/studio/studio_context_preparer.dart'),
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
      'lib/core/llm/studio/studio_context.dart',
      'lib/core/llm/studio/studio_context_preparer.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains("models/preset.dart")));
      expect(
        source,
        isNot(matches(RegExp(r'\bPreset(?:Block|Regex)?\??\s+\w+'))),
      );
    }
  });

  test('Studio request assembly excludes ordinary prompt artifacts', () {
    for (final path in [
      'lib/core/llm/memory_studio_service.dart',
      'lib/core/llm/studio/controller_phase_runner.dart',
      'lib/core/llm/studio_agent_executor.dart',
      'lib/core/llm/studio_batch_coordinator.dart',
      'lib/core/llm/studio_message_builder.dart',
      'lib/core/llm/studio/studio_runtime_block_expander.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains("prompt_builder.dart")), reason: path);
      expect(
        source,
        isNot(matches(RegExp(r'\bPrompt(?:Payload|Result)\b'))),
        reason: path,
      );
    }
  });
}
