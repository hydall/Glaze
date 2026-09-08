import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_context_policy.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';

void main() {
  test('old preset JSON preserves legacy context behavior', () {
    final preset = ExtensionPreset.fromJson({
      'id': 'p1',
      'name': 'Old',
      'blocks': [
        {'id': 'b1', 'name': 'Block'},
      ],
    });
    final policy = preset.blocks.single.contextPolicy;
    expect(policy.legacyPromptSemantics, isTrue);
    expect(policy.useMainModelContext, isFalse);
    expect(policy.includeCharacterCard, isTrue);
    expect(policy.includePersona, isTrue);
    expect(policy.includeLorebooks, isFalse);
    expect(policy.includeMemoryBooks, isFalse);
  });

  test('explicit block context policy is not treated as legacy', () {
    final preset = ExtensionPreset.fromJson({
      'id': 'p1',
      'name': 'New',
      'blocks': [
        {'id': 'b1', 'name': 'Block', 'contextPolicy': <String, Object?>{}},
      ],
    });

    expect(preset.blocks.single.contextPolicy.legacyPromptSemantics, isFalse);
  });

  test('block context policy survives preset JSON round-trip', () {
    const original = ExtensionPreset(
      id: 'p1',
      name: 'New',
      blocks: [
        BlockConfig(
          id: 'b1',
          name: 'Block',
          contextPolicy: ExtensionContextPolicy(
            useMainModelContext: true,
            includeLorebooks: true,
          ),
          contextMessageCount: -1,
        ),
      ],
    );
    final json =
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
    final decoded = ExtensionPreset.fromJson(json);
    final policy = decoded.blocks.single.contextPolicy;
    expect(policy.useMainModelContext, isTrue);
    expect(policy.includeLorebooks, isTrue);
    expect(decoded.blocks.single.contextMessageCount, -1);
    expect(json, isNot(contains('contextPolicy')));
  });

  test('preset context policy migrates only to blocks without one', () {
    final preset = ExtensionPreset.fromJson({
      'id': 'p1',
      'name': 'Migrated',
      'contextPolicy': {'includeLorebooks': true, 'messageCount': 12},
      'blocks': [
        {'id': 'b1', 'name': 'Inherited'},
        {
          'id': 'b2',
          'name': 'Explicit',
          'contextPolicy': {'includeMemoryBooks': true, 'messageCount': 3},
        },
      ],
    });

    expect(preset.blocks.first.contextPolicy.includeLorebooks, isTrue);
    expect(preset.blocks.first.contextMessageCount, 12);
    expect(preset.blocks.last.contextPolicy.includeLorebooks, isFalse);
    expect(preset.blocks.last.contextPolicy.includeMemoryBooks, isTrue);
    expect(preset.blocks.last.contextMessageCount, 3);
    expect(preset.toJson(), isNot(contains('contextPolicy')));
  });
}
