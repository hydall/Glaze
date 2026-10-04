import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';

void main() {
  late ThemePresetStorage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = ThemePresetStorage(await SharedPreferences.getInstance());
  });

  test('imports a SillyTavern theme', () async {
    final preset = await storage.importFromJson(
      jsonEncode({
        'name': 'Yellow',
        'main_text_color': 'rgba(253, 253, 253, 1)',
        'italics_text_color': 'rgba(252, 247, 137, 1)',
        'quote_text_color': 'rgba(255, 250, 107, 1)',
        'blur_tint_color': 'rgba(11, 10, 10, 0.65)',
        'user_mes_blur_tint_color': 'rgba(252, 233, 233, 0)',
        'bot_mes_blur_tint_color': 'rgba(224, 224, 219, 0)',
        'border_color': 'rgba(160, 157, 72, 0.51)',
        'blur_strength': 4,
        'hideChatAvatars_enabled': true,
        'mesIDDisplay_enabled': false,
        'message_token_count_enabled': true,
      }),
    );

    expect(preset.name, 'Yellow');
    expect(preset.author, 'SillyTavern');
    expect(preset.accentColor, '#FFFA6B');
    expect(preset.uiColor, '#0B0A0A');
    expect(preset.elementOpacity, 0.65);
    expect(preset.elementBlur, 4);
    expect(preset.showUserAvatar, isFalse);
    expect(preset.showCharAvatar, isFalse);
    expect(preset.hideMessageId, isTrue);
    expect(preset.hideTokenCount, isFalse);
  });

  test('imports portable Moonlit Echoes settings', () async {
    final preset = await storage.importFromJson(
      jsonEncode({
        'moonlitEchoesPreset': true,
        'presetName': 'Glimmer',
        'settings': {
          'customThemeColor': 'rgba(204, 204, 0, 1)',
          'customThemeColor2': 'rgba(255, 255, 255, 1)',
          'customTopBarColor': 'rgba(30, 30, 30, 1)',
          'customBgColor1': 'rgba(255, 255, 255, 0.1)',
          'customBgColor2': 'rgba(255, 255, 255, 0.05)',
          'sheldBackgroundColor': 'rgba(0, 0, 0, 0.21)',
          'sheldBlurStrength': '8',
          'messageTextFontSize': '15px',
          'rawCustomCss': 'body { display: none; }',
        },
      }),
    );

    expect(preset.name, 'Glimmer');
    expect(preset.author, 'Moonlit Echoes');
    expect(preset.accentColor, '#CCCC00');
    expect(preset.uiColor, '#1E1E1E');
    expect(preset.elementOpacity, 0.21);
    expect(preset.elementBlur, 8);
    expect(preset.chatFontSize, 15);
    expect(preset.toJson(), isNot(contains('rawCustomCss')));
  });

  test('rejects a non-object root as a format error', () async {
    await expectLater(
      storage.importFromJson('[]'),
      throwsA(isA<FormatException>()),
    );
  });

  group('built-in accent migration', () {
    Future<void> seed(Map<String, dynamic> defaultPreset) async {
      SharedPreferences.setMockInitialValues({
        'theme_presets': jsonEncode([defaultPreset]),
      });
      storage = ThemePresetStorage(await SharedPreferences.getInstance());
    }

    test('moves a legacy built-in accent to the current default', () async {
      await seed({
        'id': 'default',
        'name': 'Default',
        'accentColor': '#7996CE',
      });

      final presets = await storage.loadAll();
      expect(
        presets.firstWhere((p) => p.id == 'default').accentColor,
        '#C42A4A',
      );
      expect(
        presets.firstWhere((p) => p.id == 'material_you').accentColor,
        '#C42A4A',
      );

      final persisted = (await SharedPreferences.getInstance())
          .getString('theme_presets');
      expect(persisted, contains('#C42A4A'));
      expect(persisted, isNot(contains('7996CE')));
    });

    test('leaves a user-customised built-in accent alone', () async {
      await seed({
        'id': 'default',
        'name': 'Default',
        'accentColor': '#123456',
      });

      final presets = await storage.loadAll();
      expect(
        presets.firstWhere((p) => p.id == 'default').accentColor,
        '#123456',
      );
    });
  });
}
