import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_settings_codec.dart';

void main() {
  group('ImageGenSettingsCodec', () {
    test('round-trips the new providers and the style library', () {
      const settings = ImageGenSettings(
        apiType: ImageGenApiType.a1111,
        openrouter: OpenRouterImageSettings(
          apiKey: 'or-key',
          model: 'google/gemini-3-pro-image',
          aspectRatio: '16:9',
        ),
        electronhub: ElectronHubImageSettings(
          apiKey: 'eh-key',
          quality: 'hd',
          size: '1792x1024',
        ),
        a1111: A1111ImageSettings(
          endpoint: 'http://localhost:7861',
          steps: 30,
          cfgScale: 5.5,
          enableHr: true,
        ),
        styles: [ImageStyle(id: 's1', name: 'Anime', value: 'anime')],
        activeStyleId: 's1',
        references: [
          ReferenceImage(
            name: 'Zoe',
            imageData: 'data:image/png;base64,AAA',
            description: 'red-haired mage',
            matchMode: 'always',
            enabled: false,
          ),
        ],
      );

      final restored = ImageGenSettingsCodec.fromJson(
        ImageGenSettingsCodec.toJson(settings),
      );

      expect(restored, settings);
    });

    test('round-trips the NovelAI sub-settings', () {
      const settings = ImageGenSettings(
        apiType: ImageGenApiType.novelai,
        novelai: NovelAIImageSettings(
          apiKey: 'pst-key',
          endpoint: 'https://image.novelai.net',
          model: 'nai-diffusion-5-full',
          sampler: 'k_dpmpp_2m',
          noiseSchedule: 'exponential',
          steps: 23,
          scale: 6.5,
          cfgRescale: 0.2,
          width: 1024,
          height: 1024,
          seed: 42,
          negativePrompt: 'lowres',
          ucPreset: 'heavy',
          qualityToggle: false,
          varietyBoost: true,
        ),
      );

      final restored = ImageGenSettingsCodec.fromJson(
        ImageGenSettingsCodec.toJson(settings),
      );

      expect(restored.apiType, ImageGenApiType.novelai);
      expect(restored.novelai, settings.novelai);
    });

    test('missing NovelAI sub-settings take their defaults', () {
      final restored = ImageGenSettingsCodec.fromJson({
        'apiType': 'novelai',
      });

      expect(restored.novelai, const NovelAIImageSettings());
    });

    test('migrates the two legacy reference lists into one library', () {
      final restored = ImageGenSettingsCodec.fromJson({
        'apiType': 'routmy',
        'additionalReferences': [
          {'name': 'Zoe', 'imageData': 'zoe', 'matchMode': 'always'},
          {'name': 'Shared', 'imageData': 'shared'},
        ],
        'routmyAdditionalRefs': [
          // Same entry as in the Naistera list — must not be duplicated.
          {'name': 'Shared', 'imageData': 'shared'},
          {'name': 'Ann', 'imageData': 'ann'},
        ],
      });

      expect(restored.references.map((r) => r.name), ['Zoe', 'Shared', 'Ann']);
      expect(restored.references.first.matchMode, 'always');
      // Fields added by the overhaul get their defaults.
      expect(restored.references.first.enabled, isTrue);
      expect(restored.references.first.description, '');
    });

    test('merges the legacy per-provider avatar toggles', () {
      final restored = ImageGenSettingsCodec.fromJson({
        'naisteraSendCharAvatar': false,
        'routmySendCharAvatar': true,
        'ruRoutmySendUserAvatar': true,
      });

      expect(restored.sendCharAvatar, isTrue);
      expect(restored.sendUserAvatar, isTrue);
    });

    test('keeps the new flags when both old and new keys are present', () {
      final restored = ImageGenSettingsCodec.fromJson({
        'sendCharAvatar': false,
        'routmySendCharAvatar': true,
        'references': <Object>[],
        'additionalReferences': [
          {'name': 'Zoe', 'imageData': 'zoe'},
        ],
      });

      expect(restored.sendCharAvatar, isFalse);
      expect(restored.references, isEmpty);
    });

    test('round-trips the concurrent-generation toggle', () {
      const settings = ImageGenSettings(concurrentGeneration: true);
      final restored = ImageGenSettingsCodec.fromJson(
        ImageGenSettingsCodec.toJson(settings),
      );

      expect(restored.concurrentGeneration, isTrue);
    });

    test('settings saved before the toggle existed stay sequential', () {
      expect(
        ImageGenSettingsCodec.fromJson({
          'enabled': true,
        }).concurrentGeneration,
        isFalse,
      );
    });

    test('unknown api types fall back to openai', () {
      expect(
        ImageGenSettingsCodec.fromJson({'apiType': 'nope'}).apiType,
        ImageGenApiType.openai,
      );
      expect(
        ImageGenSettingsCodec.fromJson({'apiType': 'electronhub'}).apiType,
        ImageGenApiType.electronhub,
      );
    });
  });
}
