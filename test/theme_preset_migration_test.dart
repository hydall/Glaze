import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';

void main() {
  Map<String, dynamic> presetJson(Map<String, dynamic> extra) => {
    'id': 'custom',
    'name': 'Custom',
    ...extra,
  };

  test('legacy bgOpacity becomes its bgDim complement', () {
    final preset = themePresetFromStoredJson(
      presetJson({'bgOpacity': 0.85, 'bgDim': 0.0}),
    );

    expect(preset.bgDim, closeTo(0.15, 1e-9));
  });

  test('a fully opaque legacy background maps to no dimming', () {
    final preset = themePresetFromStoredJson(presetJson({'bgOpacity': 1.0}));

    expect(preset.bgDim, 0.0);
  });

  test('an already-dimmed legacy preset keeps the stronger value', () {
    final preset = themePresetFromStoredJson(
      presetJson({'bgOpacity': 0.9, 'bgDim': 0.5}),
    );

    expect(preset.bgDim, 0.5);
  });

  test('presets without bgOpacity decode unchanged', () {
    final preset = themePresetFromStoredJson(presetJson({'bgDim': 0.4}));

    expect(preset.bgDim, 0.4);
  });
}
