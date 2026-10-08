import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/settings/context_budget_check.dart';

PresetBlock _block(String id, String content, {bool enabled = true}) =>
    PresetBlock(
      id: id,
      name: id,
      role: 'system',
      content: content,
      enabled: enabled,
    );

void main() {
  group('presetFitsContext', () {
    test('fits while the preset stays within context minus the reply', () {
      expect(
        presetFitsContext(
          presetTokens: 3000,
          contextSize: 8000,
          maxTokens: 5000,
        ),
        isTrue,
      );
      expect(
        presetFitsContext(
          presetTokens: 3001,
          contextSize: 8000,
          maxTokens: 5000,
        ),
        isFalse,
      );
    });

    // The case a SillyTavern user brings over: the reply budget is larger than
    // the whole window, so nothing but the reply fits.
    test('a reply budget above the window leaves no room', () {
      expect(
        presetFitsContext(
          presetTokens: 1,
          contextSize: 100000,
          maxTokens: 160000,
        ),
        isFalse,
      );
    });

    test('an empty preset never blocks', () {
      expect(
        presetFitsContext(
          presetTokens: 0,
          contextSize: 100000,
          maxTokens: 160000,
        ),
        isTrue,
      );
    });
  });

  test('presetPromptTokens counts only enabled, non-stashed blocks', () {
    const counted = 'counted block text';
    final preset = Preset(
      id: 'p',
      name: 'P',
      blocks: [
        _block('a', counted),
        _block('b', 'disabled block text', enabled: false),
        _block('c', 'stashed block text').copyWith(isStashed: true),
      ],
    );

    expect(presetPromptTokens(preset), estimateTokens(counted));
  });
}
